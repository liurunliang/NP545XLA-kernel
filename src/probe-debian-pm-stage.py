#!/usr/bin/env python3
"""Run one bounded PM debug stage on the verified, full-battery Samsung boot.

Run under a transient systemd unit with a sleep/idle/lid inhibitor. This helper
never unblocks sleep targets and never selects a real sleep test. Kernel/device
hangs cannot be repaired by a userspace timeout; the original boot stays default.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

IMAGE = 'ffba40697b5364f0e48693e7b0f71bee10eec1284a4d6086664fb940a9188179'
UNIT = 'np545-gpiocharge.service'
PM = Path('/sys/power')
BATTERY = Path('/sys/class/power_supply/np545-battery')
HASHES = {
    'gpio_charge.py': '869d361dad62697fcad0d11a572a47736b94eece629777652cfce3eb6cf0ffe3',
    'np545_charge_observe.py': 'e31120090febc01d36f7aa3a2fc7018d50310cb5227c6b6b7cdbee867ab9b215',
    'irq_ack.py': '857a5d49437fc9c32efe2496a0e6117ea5cc6eee3889711f760e6a47357bbda5',
    'ic10_irq.py': '6d28c1c21efbdaff0d34d7be54baeb2f57290240b34578f493f796e4397db4d4',
    'keepcharge.py': '52796031f724a80d598f7df6ff45f50facf6cea2b62206d0b623155e930062c1',
    'hotplug.py': 'fa084ca1f85f5f141d4be554356b33c97d9bff44ed4df870d460c20bb5cdec28',
    'charge_startup.py': '9317aafd77b8306089059b999e5cd03bef37dc9dc33c122ac18102c5b4b4239a',
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def read(path):
    return Path(path).read_text().strip()


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=25)


def service(unit=UNIT):
    rows = command('systemctl', 'show', unit, '-p', 'MainPID', '-p', 'ActiveState',
                   '-p', 'Result', '-p', 'NRestarts', '-p', 'InvocationID', '-p', 'Restart')
    return dict(line.split('=', 1) for line in rows.splitlines())


def wait_full_wait(expected, timeout=10):
    """Wait for this invocation's journal delivery, without restarting anything."""
    require(re.fullmatch('[0-9a-f]{32}', expected['InvocationID']) is not None,
            'invalid charging invocation')
    deadline = time.monotonic()+timeout
    while True:
        now = service()
        require(now['ActiveState'] == 'active' and now['MainPID'] == expected['MainPID']
                and now['InvocationID'] == expected['InvocationID'] and now['NRestarts'] == '0',
                'charging invocation changed while confirming full-wait')
        messages = command('journalctl', '--no-pager', '-o', 'cat',
                           '_SYSTEMD_INVOCATION_ID='+expected['InvocationID'])
        if '"event": "full-wait"' in messages:
            return
        require(time.monotonic() < deadline, 'fresh full-wait not confirmed before deadline')
        time.sleep(0.25)


def gpio_owner():
    mux = read('/sys/kernel/debug/pinctrl/3100000.pinctrl/pinmux-pins')
    match = re.search(r'^pin 101 \(GPIO_101\): (.+)$', mux, re.M)
    require(match is not None, 'missing GPIO101 ownership')
    return match[1]


def is_gpio_released(owner, used, consumer):
    return owner == 'UNCLAIMED' and not used and not consumer


def gpio_released():
    import gpiod
    for path in sorted(Path('/dev').glob('gpiochip*')):
        with gpiod.Chip(str(path)) as chip:
            if chip.get_info().label == '3100000.pinctrl':
                info = chip.get_line_info(101)
                return is_gpio_released(gpio_owner(), info.used, info.consumer)
    raise RuntimeError('Samsung TLMM not found')


def validate_power(data):
    """Accept only the full, zero-target input-only baseline; never write I2C."""
    pd, chip, battery = data['ic10'], data['charger'], data['battery']
    require(pd.get('stable_state') and pd.get('attached') and not pd.get('source')
            and pd.get('pd_state') == 21, 'IC10 is not a stable attached sink')
    require(pd.get('requested_mV') in (5000, 12000) and pd.get('requested_mA') == 3000,
            'unexpected PD contract')
    caps = bytes.fromhex(pd['caps_hex'])
    count = (int.from_bytes(caps[:2], 'little') >> 12) & 7
    require(len(caps) == 32 and any(int.from_bytes(caps[i*4:i*4+4], 'little') == 246060
                                   for i in range(1, count+1)), 'original 12 V / 3 A source missing')
    require((chip.get('manufacturer'), chip.get('part')) == (64, 137), 'wrong charger')
    raw = chip['raw']
    require(raw['12'] == 0xe70e and raw['14'] == 0 and raw['15'] in (8400, 8696, 8760)
            and raw['22'] == raw['3f'] == 0x3c00, 'charger is not the verified zero target')
    # The board gauge reports Discharging for any negative current, even -6 mA
    # with SBS_FULL_FLAG still set. The full flag is checked independently below.
    require(98 <= battery['capacity'] <= 100 and battery['status'] in ('Full', 'Discharging')
            and abs(battery['current_now']) <= 100000
            and 6000000 <= battery['voltage_now'] <= 8760000, 'pack is not full and idle')
    require(50 <= data['temperature'] <= 400, 'pack temperature outside tested range')
    flags = data['sbs_status']
    require(flags & 0xa0 == 0xa0 and not flags & 0x9b0f, 'pack alarm or invalid full status')
    return {'pd_mV': pd['requested_mV'], 'pd_mA': pd['requested_mA'],
            'source_pdos': caps[4:4*(count+1)].hex(), 'voltage_mV': raw['15']}


def power():
    d = json.loads(command('/usr/bin/np545xla-charge-observe'))
    d['temperature'] = int(read(BATTERY/'temp'))
    d['sbs_status'] = int(read(BATTERY/'device/sbs_status'), 0)
    return d


def pm_values():
    return {n: read(PM/n) for n in ('pm_test', 'pm_async', 'pm_print_times', 'pm_debug_messages')}


def stats():
    return {p.name: read(p) for p in (PM/'suspend_stats').iterdir() if p.is_file()}


def identity(boot):
    require(read('/proc/sys/kernel/random/boot_id') == boot, 'boot ID changed')
    require(f'/boot/np545xla-sleep-debug/Image-{IMAGE}' in read('/proc/cmdline')
            and 'np545.pmdebug=1' in read('/proc/cmdline').split(), 'wrong kernel entry')
    require(command('findmnt', '-no', 'UUID', '/').strip() == 'aeb13805-ba45-4385-8a98-067b839ca579',
            'wrong root filesystem')
    for n in ('sleep', 'suspend', 'hibernate', 'hybrid-sleep', 'suspend-then-hibernate'):
        require(Path(f'/etc/systemd/system/{n}.target').readlink() == Path('/dev/null'),
                f'{n} must remain persistently masked')
    require(read('/sys/module/suspend/parameters/pm_test_delay') == '5', 'unexpected PM test delay')
    require(read('/sys/bus/platform/devices/c8c000.serial/power/wakeup') == 'disabled',
            'GPIO46 wake policy changed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=('freezer', 'devices'), required=True)
    parser.add_argument('--expected-boot', required=True)
    parser.add_argument('--output', type=Path, required=True, help='new directory for this single test')
    parser.add_argument('--check-only', action='store_true')
    a = parser.parse_args()
    require(os.geteuid() == 0, 'root required')
    a.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    with (a.output/'events.jsonl').open('x') as journal, Path('/run/np545-pm-stage.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

        def record(event, **fields):
            row = dict(event=event, boottime=time.clock_gettime(time.CLOCK_BOOTTIME),
                       monotonic=time.monotonic(), **fields)
            journal.write(json.dumps(row)+'\n'); journal.flush(); os.fsync(journal.fileno())
            print(json.dumps(row), flush=True)

        result = dict(stage=a.stage, boot_id=a.expected_boot, check_only=a.check_only,
                      stage_passed=False, charging_restored=False)
        stopped = changed_pm = False
        original = baseline = None
        try:
            identity(a.expected_boot)
            for name, expected in HASHES.items():
                actual = hashlib.sha256((Path('/usr/lib/np545xla-power')/name).read_bytes()).hexdigest()
                require(actual == expected, 'charging code mismatch: '+name)
            original = pm_values()
            require('[none]' in original['pm_test'], 'another PM test is selected')
            require(read(PM/'mem_sleep') == '[s2idle]', 'unexpected sleep mode')
            before_service = service()
            require(before_service['ActiveState'] == 'active' and int(before_service['MainPID']) > 0
                    and before_service['NRestarts'] == '0' and before_service['Restart'] == 'no',
                    'original charge service is not healthy')
            for other in ('np545-charge-sleep', 'np545-pd-hotplug', 'np545-charge-keepalive',
                          'np545-irq-ack', 'np545-ic10-irq'):
                require(service(other+'.service')['ActiveState'] in ('inactive', 'failed'),
                        'another charge controller is active: '+other)
            before_power = power()
            record('preflight-power', power=before_power)
            baseline = validate_power(before_power)
            record('preflight', service=before_service, power=before_power, pm=original,
                   stats=stats(), gpio101=gpio_owner())
            initial_trace = command('dmesg', '--raw', '--time-format=raw')
            (a.output/'dmesg-before.txt').write_text(initial_trace)
            if a.check_only:
                result['preflight_passed'] = True
                return
            # Stop through the verified service cleanup; do not write registers here.
            stopped = True
            command('systemctl', 'stop', UNIT)
            s = service(); idle = power()
            require(s['ActiveState'] == 'inactive' and s['MainPID'] == '0'
                    and s['Result'] == 'success', 'charging did not stop cleanly')
            require(gpio_released(), 'GPIO101 not released')
            require(validate_power(idle) == baseline, 'power changed after stopping service')
            record('stopped-zero-verified', service=s, power=idle, gpio101=gpio_owner())
            old_stats = stats()
            changed_pm = True
            for name, value in (('pm_async', '0'), ('pm_print_times', '1'),
                                ('pm_debug_messages', '1'), ('pm_test', a.stage)):
                (PM/name).write_text(value+'\n')
                require((f'[{value}]' in read(PM/name)) if name == 'pm_test' else read(PM/name) == value,
                        'PM setting readback failed: '+name)
            identity(a.expected_boot)
            require(service()['ActiveState'] == 'inactive', 'charge service restarted unexpectedly')
            record('stage-begin', stage=a.stage, pm=pm_values(), stats=old_stats)
            command('journalctl', '--sync'); os.sync()
            start_mono = time.monotonic(); start_boot = time.clock_gettime(time.CLOCK_BOOTTIME)
            require(f'[{a.stage}]' in read(PM/'pm_test'), 'PM selection changed')
            # Only the two early-return test modes are selectable by this program.
            (PM/'state').write_text('freeze\n')
            elapsed = time.monotonic()-start_mono
            sleep_delta = time.clock_gettime(time.CLOCK_BOOTTIME)-start_boot-elapsed
            record('stage-returned', seconds=elapsed, sleep_seconds=sleep_delta, stats=stats())
            require(elapsed >= 4, 'test returned early; inspect wake events')
            require(abs(sleep_delta) < 0.1, 'unexpected actual-sleep time')
            require(int(stats()['success']) == int(old_stats['success'])+1
                    and stats()['fail'] == old_stats['fail'], 'PM statistics indicate failure')
            trace = command('dmesg', '--raw', '--time-format=raw')
            (a.output/'dmesg-returned.txt').write_text(trace)
            marker = 'suspend debug: Waiting for 5 second(s).'
            require(trace.count(marker) == initial_trace.count(marker)+1, 'missing fresh kernel test marker')
            result.update(stage_passed=True, elapsed_seconds=elapsed, sleep_seconds=sleep_delta)
        except Exception as exc:
            result['error'] = repr(exc)
            record('stage-error', error=repr(exc))
        finally:
            try:
                if changed_pm:
                    (PM/'pm_test').write_text('none\n')
                    for name in ('pm_async', 'pm_print_times', 'pm_debug_messages'):
                        (PM/name).write_text(original[name]+'\n')
                    require(pm_values() == original, 'PM settings did not restore')
                    record('pm-restored', pm=pm_values())
                if stopped:
                    identity(a.expected_boot)
                    require('[none]' in read(PM/'pm_test'), 'cannot restart charging with PM test selected')
                    idle = power()
                    require(validate_power(idle) == baseline, 'power changed; leave charging stopped')
                    require(service()['ActiveState'] == 'inactive' and gpio_released(),
                            'unexpected charge controller before restoration')
                    command('systemctl', 'start', UNIT)
                    time.sleep(1)
                    s = service(); after = power()
                    require(s['ActiveState'] == 'active' and int(s['MainPID']) > 0
                            and s['MainPID'] != before_service['MainPID'] and s['NRestarts'] == '0',
                            'charging service did not restart normally')
                    require(validate_power(after) == baseline, 'restored power differs from baseline')
                    wait_full_wait(s)
                    result['charging_restored'] = True
                    record('charging-restored', service=s, power=after, gpio101=gpio_owner())
            except Exception as exc:
                result['restoration_error'] = repr(exc)
                record('restoration-error', error=repr(exc))
            (a.output/'dmesg-after.txt').write_text(command('dmesg', '--raw', '--time-format=raw'))
            result['passed'] = (result.get('preflight_passed', False) if a.check_only else
                                result['stage_passed'] and result['charging_restored'])
            result['passed'] = result['passed'] and 'error' not in result and 'restoration_error' not in result
            record('result', **result)
            (a.output/'result.json').write_text(json.dumps(result, indent=2)+'\n')
            os.sync()
        require('error' not in result and 'restoration_error' not in result, 'stage failed; inspect result.json')


if __name__ == '__main__':
    main()

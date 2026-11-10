#!/usr/bin/python3
"""Opt-in, per-boot handshake between the charger and systemd sleep ordering."""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import uuid

from hotplug import FIRMWARE_CHARGE, InputCharger, StopCharge, log, pack, uptime
from charge_startup import check_idle_pack

STATE = Path('/run/np545-charge-sleep')
UNIT = 'np545-charge-sleep.service'
BOOT = Path('/proc/sys/kernel/random/boot_id')
WAIT_SECONDS = 12


def state_directory():
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = STATE.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise StopCharge('sleep state directory must be a root-only directory')


def read_state(name):
    try:
        return json.loads((STATE / (name + '.json')).read_text())
    except FileNotFoundError:
        return None


def write_state(name, value):
    with tempfile.NamedTemporaryFile(mode='w', dir=STATE, delete=False) as out:
        temporary = Path(out.name)
        json.dump(value, out)
        out.write('\n')
    try:
        os.replace(temporary, STATE / (name + '.json'))
    finally:
        temporary.unlink(missing_ok=True)


def remove_state(*names):
    for name in names:
        (STATE / (name + '.json')).unlink(missing_ok=True)


def identity():
    invocation = os.environ.get('INVOCATION_ID', '')
    if len(invocation) != 32 or any(c not in '0123456789abcdef' for c in invocation):
        raise StopCharge('sleep mode requires a systemd invocation')
    return dict(boot_id=BOOT.read_text().strip(), pid=os.getpid(), invocation=invocation)


def same_identity(a, b):
    return bool(a and b and all(a.get(k) == b.get(k) for k in ('boot_id', 'pid', 'invocation')))


class SleepPause:
    def __init__(self):
        state_directory()
        self.identity = identity()
        self.requested = False
        self.proof = None
        self.retained = None

    def ready(self):
        remove_state('request', 'ack', 'failed')
        write_state('running', self.identity)

    def request(self):
        self.requested = True

    def request_data(self):
        request = read_state('request')
        if (not same_identity(request, self.identity) or not isinstance(request.get('token'), str)
                or len(request['token']) != 32 or not 0 <= uptime() - request.get('at', -1) <= 18):
            raise StopCharge('missing, stale or mismatched sleep request')
        return request

    def retain(self, sink, chip, known, input_voltage, charge_voltage):
        if not self.requested:
            return False
        self.request_data()
        # The charging loop already wrote/read back zero before this callback.
        chip.settings(0, voltage=charge_voltage)
        chip.check_limits()
        sink.check(known, input_voltage)
        if not chip.input_present() or sink.switches() != 1:
            raise StopCharge('sleep preparation lost the verified input path')
        check_idle_pack(pack())
        self.retained = dict(input_mV=input_voltage, charge_mV=charge_voltage,
                             pdo=list(known), consumer=1)
        log('sleep-input-retained', readback_mA=0, **self.retained)
        return True

    def finish(self, chip):
        if not self.requested:
            return
        request = self.request_data()
        chip.identify()
        voltage, current = chip.word(0x15), chip.word(0x14)
        if current not in (0, *range(64, 1025, 64), FIRMWARE_CHARGE.get(voltage)):
            raise StopCharge('unknown target before sleep')
        chip.settings(current, voltage=voltage)
        # An unplugged startup may still have a known inactive firmware preset.
        if current:
            chip.set_current(0)
        chip.settings(0, voltage=voltage)
        check_idle_pack(pack())
        if self.retained is None and chip.input_present():
            raise StopCharge('sleep input was not verified for retention')
        if self.retained is not None and voltage != self.retained['charge_mV']:
            raise StopCharge('sleep voltage changed after input verification')
        self.proof = {**request, 'zero_mA': 0, 'charge_mV': voltage,
                      'input': self.retained, 'verified_at': uptime()}

    def released(self):
        # Called only after the ExitStack has closed GPIO and every I2C handle.
        if self.requested:
            self.request_data()
            if self.proof is None:
                raise StopCharge('sleep preparation has no zero-current proof')
            write_state('ack', self.proof)
            log('sleep-prepared', **self.proof)

    def close(self):
        if same_identity(read_state('running'), self.identity):
            remove_state('running')


def service_state():
    result = subprocess.run(['systemctl', 'show', UNIT, '-p', 'ActiveState', '-p', 'MainPID',
                             '-p', 'InvocationID', '-p', 'ExecMainStatus', '-p', 'Result'],
                            check=True, text=True, stdout=subprocess.PIPE, timeout=5)
    return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)


def matches_service(record, service):
    return (record and record.get('boot_id') == BOOT.read_text().strip()
            and record.get('pid') == int(service.get('MainPID', 0))
            and record.get('invocation') == service.get('InvocationID')
            and service.get('ActiveState') == 'active')


def valid_ack(request, ack):
    return bool(same_identity(request, ack) and request.get('token') == ack.get('token')
                and ack.get('zero_mA') == 0 and ack.get('charge_mV') in (8400, *FIRMWARE_CHARGE)
                and ack.get('verified_at', -1) >= request.get('at', 0))


def verify_zero(ack):
    # The sole hardware operation in the guard is this independent read check.
    with InputCharger() as chip:
        chip.identify()
        chip.settings(0, voltage=ack['charge_mV'])


def check_enabled():
    required = subprocess.check_output(['systemctl', 'show', 'sleep.target', '-p', 'Requires', '--value'],
                                       text=True, timeout=5).split()
    before = subprocess.check_output(['systemctl', 'show', 'np545-charge-sleep-guard.service',
                                      '-p', 'Before', '--value'], text=True, timeout=5).split()
    if 'np545-charge-sleep-guard.service' not in required or 'sleep.target' not in before:
        raise StopCharge('enable the required sleep guard before starting this candidate')


def prepare():
    state_directory()
    service = service_state()
    running = read_state('running')
    if not matches_service(running, service):
        raise StopCharge('sleep charger is not active and ready')
    request = {**running, 'token': uuid.uuid4().hex, 'at': uptime()}
    remove_state('ack', 'failed')
    write_state('request', request)
    try:
        # Address the systemd main process, never a PID taken only from a file.
        subprocess.run(['systemctl', 'kill', '--kill-whom=main', '--signal=SIGUSR1', UNIT],
                       check=True, timeout=5)
        until = uptime() + WAIT_SECONDS
        while uptime() < until:
            service = service_state()
            ack = read_state('ack')
            if service.get('ActiveState') in ('failed', 'inactive'):
                if (service.get('ActiveState') != 'inactive' or service.get('ExecMainStatus') != '0'
                        or service.get('Result') != 'success' or not valid_ack(request, ack)):
                    raise StopCharge('charger exited without a successful sleep preparation')
                verify_zero(ack)
                log('sleep-admitted', token=request['token'], zero_mA=0, input=ack['input'])
                return
            time.sleep(0.05)
        raise StopCharge('timed out waiting for the charger to release its resources')
    except BaseException:
        write_state('failed', {'token': request['token']})
        raise


def resume():
    state_directory()
    request, ack, failed = read_state('request'), read_state('ack'), read_state('failed')
    if request is None:
        return
    if (request.get('boot_id') != BOOT.read_text().strip() or not valid_ack(request, ack)
            or (failed and failed.get('token') == request.get('token'))):
        log('sleep-resume-skipped', reason='no successful preparation from this boot')
        return
    service = service_state()
    if (service.get('ActiveState') != 'inactive' or service.get('ExecMainStatus') != '0'
            or service.get('Result') != 'success'):
        raise StopCharge('sleep charger changed before resume')
    # Consume before starting: a failed restart is never retried by replaying ACK.
    remove_state('request', 'ack', 'failed')
    subprocess.run(['systemctl', 'start', '--no-block', UNIT], check=True, timeout=5)
    until = uptime() + WAIT_SECONDS
    while uptime() < until:
        service = service_state()
        running = read_state('running')
        if matches_service(running, service) and running['invocation'] != request['invocation']:
            log('sleep-resumed', previous_pid=request['pid'], pid=running['pid'],
                invocation=running['invocation'])
            return
        if service.get('ActiveState') == 'failed':
            raise StopCharge('sleep charger failed during resume')
        time.sleep(0.05)
    raise StopCharge('sleep charger did not become ready after resume')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'resume', 'check-enabled'))
    args = parser.parse_args()
    try:
        {'prepare': prepare, 'resume': resume, 'check-enabled': check_enabled}[args.action]()
    except (StopCharge, OSError, ValueError, subprocess.SubprocessError) as exc:
        log('sleep-error', action=args.action, reason=str(exc))
        raise SystemExit(1)

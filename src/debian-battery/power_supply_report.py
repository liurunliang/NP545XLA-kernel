#!/usr/bin/python3
"""Report the validated IC10 controller's state; never control charging hardware."""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import signal
import struct
import subprocess
import threading
import time

POWERLIB = Path('/usr/lib/np545xla-power')
SERVICE = 'np545-gpiocharge.service'
DEVICE = '/dev/np545-power-supply'
FRAME = struct.Struct('<IIQ6I')
EVIDENCE_SECONDS = 65
# These versions have measured, documented full-sample/refresh semantics.
# A controller upgrade requires reviewing its event contract, not blindly trusting JSON.
HASHES = {
    'gpio_charge.py': '869d361dad62697fcad0d11a572a47736b94eece629777652cfce3eb6cf0ffe3',
    'np545_charge_observe.py': 'e31120090febc01d36f7aa3a2fc7018d50310cb5227c6b6b7cdbee867ab9b215',
    'irq_ack.py': '857a5d49437fc9c32efe2496a0e6117ea5cc6eee3889711f760e6a47357bbda5',
    'ic10_irq.py': '6d28c1c21efbdaff0d34d7be54baeb2f57290240b34578f493f796e4397db4d4',
    'keepcharge.py': '52796031f724a80d598f7df6ff45f50facf6cea2b62206d0b623155e930062c1',
    'hotplug.py': 'fa084ca1f85f5f141d4be554356b33c97d9bff44ed4df870d460c20bb5cdec28',
    'charge_startup.py': '9317aafd77b8306089059b999e5cd03bef37dc9dc33c122ac18102c5b4b4239a',
}


def check_sources():
    for name, digest in HASHES.items():
        if hashlib.sha256((POWERLIB / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f'unreviewed status producer: {name}')


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=3).stdout


def controller():
    fields = dict(line.split('=', 1) for line in command(
        'systemctl', 'show', SERVICE, '-p', 'ActiveState', '-p', 'InvocationID',
        '-p', 'MainPID').splitlines())
    if (fields.get('ActiveState') != 'active' or int(fields.get('MainPID', '0')) <= 0
            or len(fields.get('InvocationID', '')) != 32):
        raise ValueError('charging controller is not active')
    return fields['InvocationID']


def evidence(rows, boot_id, invocation, now):
    """Only current trusted journal records can establish input-path continuity.

    Unknown subsequent controller events invalidate a positive observation. Journal
    receipt time is not sample time (delivery can lag); use the producer's boottime.
    """
    latest = None
    for row in rows:
        if (row.get('_BOOT_ID') != boot_id.replace('-', '')
                or row.get('_SYSTEMD_INVOCATION_ID') != invocation
                or row.get('_SYSTEMD_UNIT') != SERVICE or row.get('_UID') != '0'):
            continue
        try:
            event = json.loads(row['MESSAGE'])
            if 'boottime' in event:
                stamp = event['boottime']
            else:
                stamp_ns = event['boottime_ns']
                if type(stamp_ns) is not int:
                    return None
                stamp = stamp_ns / 1e9
                event['boottime'] = stamp
            if (type(stamp) not in (int, float) or not math.isfinite(stamp)
                    or not 0 <= stamp <= now + 0.001):
                return None
            if latest is not None and stamp < latest['boottime']:
                return None
            latest = event
        except (KeyError, TypeError, ValueError):
            # systemd lifecycle messages are not controller stdout.
            if row.get('_TRANSPORT') == 'stdout':
                return None
    if latest is None or now - latest['boottime'] > EVIDENCE_SECONDS:
        return None
    if latest.get('event') == 'full-sample' and latest.get('readback_mA') == 0:
        return latest
    if latest.get('event') == 'refresh' and latest.get('ac') is True:
        return latest
    return None


def map_state(pd, chip, proof):
    """Return valid mask, online, negotiated limits and programmed targets (SI micro units)."""
    unknown = (0,) * 7
    if not pd.get('stable_state') or pd.get('source') is not False:
        return unknown
    state = int(pd['state_hex'], 16)
    if state & 0xe2000000:
        return unknown
    if pd.get('attached') is False and pd.get('pd_state') == 0:
        return (1, 0, 0, 0, 0, 0, 0)
    if (pd.get('attached') is not True or pd.get('pd_state') != 21
            or pd.get('requested_mV') not in (5000, 12000)
            or pd.get('requested_mA') != 3000 or proof is None):
        return unknown
    raw = chip.get('raw', {})
    current, voltage = chip.get('current_setting_mA'), chip.get('voltage_setting_mV')
    if (chip.get('error') or (chip.get('manufacturer'), chip.get('part')) != (0x40, 0x89)
            or raw.get('12') != 0xe70e or raw.get('22') != 0x3c00 or raw.get('3f') != 0x3c00
            or type(current) is not int or not 0 <= current <= 1024 or current % 64
            or voltage not in (8400, 8696, 8760) or (voltage == 8400 and current)
            or raw.get('14') != current or raw.get('15') != voltage
            or proof.get('readback_mA') != current):
        return unknown
    return (7, 1, pd['requested_mV'] * 1000, pd['requested_mA'] * 1000,
            3000000, current * 1000, voltage * 1000)


def encode(state, stamp_ns):
    valid, online, uv, ua, input_ua, charge_ua, charge_uv = state
    return FRAME.pack(1, valid, stamp_ns, online, uv, ua, input_ua, charge_ua, charge_uv)


def collect(observer):
    check_sources()
    started = time.clock_gettime_ns(time.CLOCK_BOOTTIME)
    invocation = controller()
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    pd = observer.port('ic10')
    # Read only the allowlisted observer registers, never ChargerStatus (0x20).
    chip = observer.charger() if pd.get('attached') else {}
    again = observer.port('ic10')
    rows = [json.loads(line) for line in command(
        'journalctl', '-b', '-u', SERVICE, f'_SYSTEMD_INVOCATION_ID={invocation}',
        '-n', '100', '-o', 'json', '--no-pager').splitlines()]
    now = time.clock_gettime(time.CLOCK_BOOTTIME)
    if controller() != invocation or pd != again or now - started / 1e9 > 3:
        raise ValueError('status changed or collection took too long')
    return map_state(pd, chip, evidence(rows, boot, invocation, now)), started


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--once', action='store_true', help='print one snapshot; do not open the bridge')
    args = parser.parse_args()
    if b'samsung,np545xla' not in Path('/sys/firmware/devicetree/base/compatible').read_bytes().split(b'\0'):
        parser.error('Samsung NP545XLA only')
    check_sources()
    spec = importlib.util.spec_from_file_location('observer', POWERLIB / 'np545_charge_observe.py')
    observer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(observer)
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    fd = None if args.once else os.open(DEVICE, os.O_WRONLY | os.O_CLOEXEC)
    previous = None
    try:
        while not stop.is_set():
            error = None
            try:
                state, stamp = collect(observer)
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
                state, stamp = (0,) * 7, time.clock_gettime_ns(time.CLOCK_BOOTTIME)
                error = str(exc)
            if fd is not None:
                frame = encode(state, stamp)
                if os.write(fd, frame) != len(frame):
                    raise OSError('short bridge write')
            if args.once or (state, error) != previous:
                print(json.dumps(dict(boottime_ns=stamp, state=state, error=error)), flush=True)
                previous = (state, error)
            if args.once:
                return
            stop.wait(5)
    finally:
        if fd is not None:
            os.close(fd)


if __name__ == '__main__':
    main()

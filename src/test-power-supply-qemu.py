#!/usr/bin/env python3
"""Test the actual status module/ABI in a network-free ARM64 QEMU guest."""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import subprocess

INIT = r'''#!/bin/sh
export PATH=/bin
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
if /bin/busybox insmod /bridge.ko; then
    echo NP545_POWER_FAIL_board_guard
else
    echo NP545_POWER_BOARD_GUARD_PASS
    if /bin/busybox insmod /bridge.ko test_mode=1; then
        /abi-test
        /bin/busybox rmmod np545_power_supply || echo NP545_POWER_FAIL_unload
    else
        echo NP545_POWER_FAIL_load
    fi
fi
/bin/busybox poweroff -f
while :; do /bin/busybox sleep 1; done
'''


def archive(files):
    data = bytearray()

    def add(name, mode, content=b'', major=0, minor=0):
        encoded = name.encode() + b'\0'
        fields = (0, mode, 0, 0, 1, 0, len(content), 0, 0, major, minor, len(encoded), 0)
        data.extend(b'070701' + ''.join(f'{v:08x}' for v in fields).encode())
        data.extend(encoded)
        data.extend(b'\0' * (-len(data) % 4))
        data.extend(content)
        data.extend(b'\0' * (-len(data) % 4))

    for directory in ('bin', 'dev', 'sys', 'proc'):
        add(directory, stat.S_IFDIR | 0o755)
    add('dev/console', stat.S_IFCHR | 0o600, major=5, minor=1)
    add('bin/sh', stat.S_IFLNK | 0o777, b'busybox')
    add('init', stat.S_IFREG | 0o755, INIT.encode())
    for name, path in files.items():
        add(name, stat.S_IFREG | 0o755, path.read_bytes())
    add('TRAILER!!!', 0)
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('image', 'busybox', 'module', 'client', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    files = {'bin/busybox': args.busybox, 'bridge.ko': args.module, 'abi-test': args.client}
    cpio = args.output.resolve() / 'test.cpio'
    cpio.write_bytes(archive(files))
    serial = args.output.resolve() / 'serial.log'
    command = [args.qemu, '-nodefaults', '-machine', 'virt,acpi=off,gic-version=3',
               '-accel', 'hvf', '-cpu', 'host', '-m', '768', '-smp', '2',
               '-display', 'none', '-monitor', 'none', '-nic', 'none', '-no-reboot',
               '-serial', f'file:{serial}', '-kernel', str(args.image.resolve()),
               '-initrd', str(cpio), '-append', 'console=ttyAMA0,115200 rdinit=/init loglevel=6 panic=1']
    result = dict(passed=False, physical_hardware_test=False, command=command,
                  sha256={k: hashlib.sha256(v.read_bytes()).hexdigest()
                          for k, v in dict(files, image=args.image).items()})
    try:
        with (args.output / 'qemu.log').open('w') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            try:
                result['exit'] = process.wait(timeout=60)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        trace = serial.read_text(errors='replace')
        assert result['exit'] == 0
        assert 'NP545_POWER_BOARD_GUARD_PASS' in trace
        assert 'NP545_POWER_PASS checks=' in trace
        assert not any(s in trace for s in ('NP545_POWER_FAIL', 'BUG:', 'WARNING:', 'Oops:'))
        result['passed'] = True
    finally:
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

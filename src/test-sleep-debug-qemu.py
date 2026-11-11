#!/usr/bin/env python3
"""Exercise PM freezer/devices test modes in QEMU, without physical hardware."""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import struct
import subprocess


INIT = r'''#!/bin/sh
export PATH=/bin
fail() {
    echo "NP545_PM_DEBUG_FAIL: $*"
    /bin/busybox poweroff -f
    while :; do /bin/busybox sleep 1; done
}
/bin/busybox mount -t proc proc /proc || fail proc
/bin/busybox mount -t sysfs sysfs /sys || fail sysfs
/bin/busybox mount -t devtmpfs devtmpfs /dev || fail devtmpfs
echo NP545_PM_DEBUG_BEGIN
test -r /sys/power/pm_test || fail missing-pm-test
/bin/busybox cat /sys/power/pm_test
for mode in freezer devices; do
    echo "$mode" > /sys/power/pm_test || fail "select-$mode"
    selected=$(/bin/busybox cat /sys/power/pm_test)
    case "$selected" in
        *"[$mode]"*) ;;
        *) fail "readback-$mode" ;;
    esac
    echo "NP545_PM_TEST_BEGIN $mode"
    echo freeze > /sys/power/state || fail "execute-$mode"
    echo "NP545_PM_TEST_PASS $mode"
done
echo none > /sys/power/pm_test || fail reset
selected=$(/bin/busybox cat /sys/power/pm_test)
case "$selected" in *'[none]'*) ;; *) fail reset-readback ;; esac
echo NP545_PM_DEBUG_PASS
/bin/busybox sync
/bin/busybox poweroff -f
while :; do /bin/busybox sleep 1; done
'''


def initramfs(busybox):
    """Create the small reproducible newc archive required by direct kernel boot."""
    output = bytearray()

    def add(name, mode, data=b'', major=0, minor=0):
        encoded = name.encode() + b'\0'
        fields = (0, mode, 0, 0, 1, 0, len(data), 0, 0, major, minor, len(encoded), 0)
        output.extend(b'070701' + ''.join(f'{v:08x}' for v in fields).encode())
        output.extend(encoded)
        output.extend(b'\0' * (-len(output) % 4))
        output.extend(data)
        output.extend(b'\0' * (-len(output) % 4))

    for directory in ('bin', 'dev', 'proc', 'sys'):
        add(directory, stat.S_IFDIR | 0o755)
    add('dev/console', stat.S_IFCHR | 0o600, major=5, minor=1)
    add('dev/null', stat.S_IFCHR | 0o666, major=1, minor=3)
    add('bin/busybox', stat.S_IFREG | 0o755, busybox)
    add('bin/sh', stat.S_IFLNK | 0o777, b'busybox')
    add('init', stat.S_IFREG | 0o755, INIT.encode())
    add('TRAILER!!!', 0)
    return bytes(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--busybox', type=Path, required=True,
                        help='a statically linked ARM64 BusyBox binary')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--accel', choices=('hvf', 'tcg'), default='hvf')
    parser.add_argument('--timeout', type=int, default=90)
    args = parser.parse_args()
    if args.timeout < 15:
        parser.error('allow at least 15 seconds for both five-second PM tests')
    args.image = args.image.resolve(strict=True)
    binary = args.busybox.read_bytes()
    if len(binary) < 20 or binary[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', binary, 18)[0] != 183:
        parser.error('BusyBox must be an ARM64 little-endian ELF64 binary')
    args.output.mkdir(parents=True, exist_ok=False)
    archive = args.output / 'test-initramfs.cpio'
    archive.write_bytes(initramfs(binary))
    serial = args.output.resolve() / 'serial.log'
    command = [args.qemu, '-nodefaults', '-machine', 'virt,acpi=off,gic-version=3',
               '-accel', args.accel, '-cpu', 'host' if args.accel == 'hvf' else 'max',
               '-m', '768', '-smp', '2', '-display', 'none', '-monitor', 'none',
               '-nic', 'none', '-serial', f'file:{serial}', '-no-reboot',
               '-kernel', str(args.image), '-initrd', str(archive.resolve()),
               '-append', 'console=ttyAMA0,115200 rdinit=/init loglevel=6 panic=1']
    result = {'command': command, 'image_sha256': hashlib.sha256(args.image.read_bytes()).hexdigest(),
              'busybox_sha256': hashlib.sha256(binary).hexdigest(), 'passed': False,
              'physical_hardware_test': False}
    try:
        with (args.output / 'qemu.log').open('w') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            try:
                result['exit'] = process.wait(timeout=args.timeout)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        trace = serial.read_text(errors='replace')
        assert result['exit'] == 0, result['exit']
        assert 'NP545_PM_DEBUG_FAIL' not in trace
        for mode in ('freezer', 'devices'):
            assert trace.count(f'NP545_PM_TEST_PASS {mode}') == 1, mode
        assert 'NP545_PM_DEBUG_PASS' in trace
        result['passed'] = True
    except (OSError, subprocess.TimeoutExpired, AssertionError) as exc:
        result['error'] = str(exc)
        raise
    finally:
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

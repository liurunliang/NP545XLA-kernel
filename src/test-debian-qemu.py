#!/usr/bin/env python3
"""Cold-boot the persistent USB image using ACPI and disposable write overlays."""
import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid


CHECK_BOOT = """
test "$(id -u)" -ne 0
test "$(sudo -n id -u)" = 0
test "$(uname -m)" = aarch64
test -f /sys/firmware/acpi/tables/DSDT
grep -qw 'diag.mode=acpi' /proc/cmdline
test "$(findmnt -n -o FSTYPE /)" = ext4
findmnt -n -o SOURCE,FSTYPE,OPTIONS,UUID /
disk=$(findmnt -n -o SOURCE /)
readlink -f "/sys/class/block/${disk##*/}" | grep '/usb[0-9][0-9]*/'
findmnt -n -o OPTIONS / | tr ',' '\\n' | grep -Fx rw
ip -4 -o addr show scope global
sudo -n sh -c "grep -h '^ADDRESS=' /run/systemd/netif/leases/*"
ip route show default | grep '^default '
systemctl is-active systemd-resolved
systemctl is-active systemd-timesyncd
test -f /var/lib/systemd/timesync/clock
"""


def root_offset(image):
    """Find the single ext4 Linux filesystem on the original GPT USB image."""
    linux_data = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4").bytes_le
    with image.open("rb") as disk:
        disk.seek(512)
        header = disk.read(512)
        if header[:8] != b"EFI PART":
            raise ValueError("expected a 512-byte-sector GPT image")
        table, count, size = struct.unpack_from("<QII", header, 72)
        if not 1 <= count <= 4096 or not 128 <= size <= 4096:
            raise ValueError("invalid GPT partition array")
        disk.seek(table * 512)
        entries = [disk.read(size) for _ in range(count)]
        roots = [struct.unpack_from("<Q", e, 32)[0] * 512 for e in entries if e[:16] == linux_data]
        if len(roots) != 1:
            raise ValueError("expected exactly one Linux filesystem data partition")
        disk.seek(roots[0] + 1024 + 56)
        if disk.read(2) != b"\x53\xef":
            raise ValueError("expected an ext4 superblock in the Linux partition")
        return roots[0]


def wait_for(process, description, ready, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if ready():
            return
        if process.poll() is not None:
            raise RuntimeError(f"QEMU exited before {description}")
        time.sleep(1)
    raise TimeoutError(f"timed out waiting for {description}")


def serial_text(path):
    return path.read_text(errors="replace") if path.exists() else ""


def drive_path(path):
    return str(path).replace(",", ",,")


@contextmanager
def boot(args, scratch, overlay, name, guest_port):
    serial = args.output / f"{name}.serial.log"
    vars_fd = scratch / f"{name}.fd"
    shutil.copyfile(args.firmware / "edk2-arm-vars.fd", vars_fd)
    port = args.port if guest_port == 2223 else args.port + 1
    command = [
        args.qemu, "-nodefaults", "-machine", "virt,acpi=on,gic-version=3",
        "-accel", args.accel, "-cpu", "host" if args.accel == "hvf" else "max",
        "-m", "1536", "-smp", "2", "-display", "none", "-monitor", "none",
        "-serial", f"file:{serial}", "-no-reboot",
        "-smbios", "type=1,manufacturer=QEMU,product=NP545XLA-DEBIAN-QEMU",
        "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=" + drive_path(args.firmware / "edk2-aarch64-code.fd"),
        "-drive", "if=pflash,format=raw,unit=1,file=" + drive_path(vars_fd),
        "-drive", "if=none,id=stick,format=qcow2,file=" + drive_path(overlay),
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-storage,bus=xhci.0,drive=stick,removable=on,bootindex=1",
        "-netdev", f"user,id=wired,hostfwd=tcp:127.0.0.1:{port}-:{guest_port}",
        "-device", "virtio-net-pci,netdev=wired",
    ]
    print(f"Booting {name} over USB", flush=True)
    with (args.output / f"{name}.qemu.log").open("w") as log:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            yield process, serial, port
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def verify_host(args, vm, name, previous=None):
    process, serial, port = vm
    def key_ready():
        trace = serial_text(serial)
        if name != "rescue" and "DEBIAN ROOT RESCUE:" in trace:
            raise RuntimeError(f"{name} unexpectedly entered rescue; see {serial}")
        return "Host key: SHA256:" in trace

    wait_for(process, f"{name} console fingerprint",
             key_ready, args.timeout)
    path = args.output / f"{name}.known_hosts"

    def scan():
        key = subprocess.run(["ssh-keyscan", "-T", "3", "-p", str(port), "-t", "ed25519", "127.0.0.1"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if key.returncode == 0 and key.stdout.strip():
            path.write_bytes(key.stdout)
            return True
        return False

    wait_for(process, f"{name} SSH host key", scan, args.timeout)
    fp = subprocess.check_output(["ssh-keygen", "-E", "sha256", "-lf", path], text=True).split()[1]
    if f"Host key: {fp}" not in serial_text(serial) or (previous and previous != fp):
        raise RuntimeError(f"{name} SSH fingerprint mismatch: {fp}")
    print(f"{name}: verified console and SSH key {fp}", flush=True)
    return path, fp


def ssh(args, port, user, known_hosts, script, output):
    cmd = [
        "ssh", "-F", "/dev/null", "-p", str(port), "-i", str(args.identity),
        "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=7",
        "-o", "PreferredAuthentications=publickey", "-o", "HostKeyAlgorithms=ssh-ed25519",
        "-o", "StrictHostKeyChecking=yes", "-o", f'UserKnownHostsFile="{known_hosts}"',
        "-o", "GlobalKnownHostsFile=/dev/null", f"{user}@127.0.0.1", "sh -se",
    ]
    with (args.output / output).open("w") as log:
        subprocess.run(cmd, input=script, text=True, stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=args.timeout)


def overlay_for(args, scratch, name):
    overlay = scratch / f"{name}.qcow2"
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-o", "backing_fmt=raw",
                    "-b", args.image, overlay], check=True)
    return overlay


def test(args, scratch):
    offset = root_offset(args.image)
    persistence = overlay_for(args, scratch, "persistent")
    token = str(uuid.uuid4())
    with boot(args, scratch, persistence, "install", 2223) as vm:
        host, fingerprint = verify_host(args, vm, "install")
        install = f"""
if dpkg-query -W -f='${{db:Status-Status}}' hello 2>/dev/null | grep -qx installed; then
    echo 'Test needs a fresh image without hello' >&2; exit 1
fi
sudo -n apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=1 -o Acquire::http::Timeout=25 update
sudo -n env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install hello
hello
printf '%s\\n' '{token}' | sudo -n tee /var/lib/np545xla-qemu-persistence
cat /proc/sys/kernel/random/boot_id
sync
"""
        ssh(args, vm[2], args.user, host, CHECK_BOOT + install, "install.checks.log")
        ssh(args, vm[2], args.user, host, "sudo -n systemctl --no-block poweroff", "poweroff.log")
        vm[0].wait(timeout=args.timeout)

    with boot(args, scratch, persistence, "reboot", 2223) as vm:
        host, second = verify_host(args, vm, "reboot", fingerprint)
        persist = f"""
test "$(cat /var/lib/np545xla-qemu-persistence)" = '{token}'
dpkg-query -W -f='${{db:Status-Status}}\\n' hello | grep -Fx installed
hello
cat /proc/sys/kernel/random/boot_id
"""
        ssh(args, vm[2], args.user, host, CHECK_BOOT + persist, "reboot.checks.log")
        first_id = (args.output / "install.checks.log").read_text().splitlines()[-1]
        second_id = (args.output / "reboot.checks.log").read_text().splitlines()[-1]
        if uuid.UUID(first_id) == uuid.UUID(second_id):
            raise RuntimeError("guest boot ID did not change")
        print(f"Package, marker and SSH key persisted across boots ({second})", flush=True)

    rescue = overlay_for(args, scratch, "missing-root")
    # Clear only the ext4 primary superblock in this disposable overlay.
    subprocess.run(["qemu-io", "-f", "qcow2", "-c", f"write -z {offset + 1024} 1024", rescue], check=True)
    with boot(args, scratch, rescue, "rescue", 2222) as vm:
        wait_for(vm[0], "missing-root rescue", lambda: "DEBIAN ROOT RESCUE:" in serial_text(vm[1]), args.timeout)
        host, _ = verify_host(args, vm, "rescue")
        ssh(args, vm[2], "root", host,
            "test \"$(id -u)\" = 0\ncat /run/diagnostics/report.txt", "rescue.report.txt")
        report = (args.output / "rescue.report.txt").read_text()
        if "Firmware: ACPI" not in report or "Disk mounts: none" not in report:
            raise RuntimeError("rescue did not reach disk-free ACPI diagnostics")

    subprocess.run([Path(__file__).with_name("test-diag-qemu.sh"), "--image", args.image,
                    "--identity", args.identity, "--output", args.output / "diagnostics",
                    "--port", str(args.port + 1)], check=True)
    print(f"All five USB boots passed. Evidence in {args.output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--identity", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--user", default="liurunliang")
    parser.add_argument("--port", type=int, default=22003, help="First of two loopback ports")
    args = parser.parse_args()
    args.image, args.identity = args.image.resolve(strict=True), args.identity.resolve(strict=True)
    if not args.image.is_file() or not args.identity.is_file() or not 1 <= args.port <= 65534:
        parser.error("supply regular input files and a host port from 1 to 65534")
    args.output = args.output.resolve()
    args.qemu = shutil.which("qemu-system-aarch64")
    if not args.qemu:
        parser.error("qemu-system-aarch64 is required")
    args.accel = os.environ.get("QEMU_ACCEL", "hvf")
    if args.accel not in ("hvf", "tcg"):
        parser.error("QEMU_ACCEL must be hvf or tcg")
    args.timeout = int(os.environ.get("QEMU_TIMEOUT", "420"))
    args.firmware = Path(os.environ.get("QEMU_FIRMWARE_DIR", Path(args.qemu).parent.parent / "share/qemu"))
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory() as scratch:
        test(args, Path(scratch))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))

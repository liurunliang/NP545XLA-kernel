#!/usr/bin/env python3
"""Boot a GRUB-only probe disk twice; never boots or modifies Samsung hardware."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--disk", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
a.output.mkdir()
disk = a.output / "test.img"
shutil.copy2(a.disk, disk)
qemu = Path(shutil.which("qemu-system-aarch64"))
firmware = qemu.parent.parent / "share/qemu"
header = b"# GRUB Environment Block\n"
data = disk.read_bytes()
needle = b"np545_passive_once=1\n"
assert data.count(needle) == 1
variable_offset = data.index(needle)
offset = data.rfind(header, 0, variable_offset)
assert 0 <= offset < variable_offset < offset + 1024


def flag():
    with disk.open("rb") as f:
        f.seek(offset)
        block = f.read(1024)
    assert block.startswith(header)
    matches = re.findall(rb"^np545_passive_once=([01])$", block, re.M)
    assert len(matches) == 1
    return matches[0].decode()


assert flag() == "1"
results = []
for label, expected in (("armed", "Debian-passive-charge"), ("next-boot", "Debian-latest-media")):
    variables = a.output / (label + ".vars.fd")
    shutil.copy2(firmware / "edk2-arm-vars.fd", variables)
    serial = a.output / (label + ".serial.log")
    cmd = [str(qemu), "-nodefaults", "-machine", "virt,acpi=on,gic-version=3",
           "-accel", "hvf", "-cpu", "host", "-m", "512", "-smp", "2",
           "-display", "none", "-monitor", "none", "-serial", f"file:{serial}", "-nic", "none",
           "-smbios", "type=1,manufacturer=Samsung,product=Galaxy Book Go 5G",
           "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={firmware / 'edk2-aarch64-code.fd'}",
           "-drive", f"if=pflash,format=raw,unit=1,file={variables}",
           "-drive", f"if=none,id=stick,format=raw,file={disk}",
           "-device", "qemu-xhci,id=xhci",
           "-device", "usb-storage,bus=xhci.0,drive=stick,removable=on,bootindex=1"]
    with (a.output / (label + ".qemu.log")).open("w") as log:
        process = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 50
            while time.monotonic() < deadline:
                text = serial.read_text(errors="replace") if serial.exists() else ""
                text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text).replace("\r", "")
                if "NP545_PASSIVE_PROBE_END" in text:
                    break
                if process.poll() is not None:
                    raise RuntimeError(f"{label}: QEMU exited before probe")
                time.sleep(0.25)
            else:
                raise TimeoutError(f"{label}: GRUB probe timed out")
            assert f"NP545_PASSIVE_PROBE_ENTRY={expected}" in text, text[-3000:]
            if label == "armed":
                assert "NP545_PASSIVE_ARG=np545.chargepassive=1" in text
                assert "NP545_PASSIVE_ARG=np545.gpiocharge=1" not in text
                assert "NP545_PASSIVE_ARG=systemd.mask=np545-gpiocharge.service" in text
            else:
                assert "NP545_PASSIVE_ARG=np545.gpiocharge=1" in text
                assert "NP545_PASSIVE_ARG=np545.chargepassive=1" not in text
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    assert flag() == "0", "one-shot was not consumed before kernel handoff"
    results.append({"phase": label, "selected": expected, "saved_flag": flag()})
    print(json.dumps(results[-1]), flush=True)
(a.output / "result.json").write_text(json.dumps({
    "passed": True, "boots": results,
    "scope": "Real GRUB menu selection and FAT one-shot writes. Test-only functions replace kernel preparation/handoff; no Linux or charging acceptance.",
}, indent=2) + "\n")

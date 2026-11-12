#!/usr/bin/env python3
"""Verify the deliverable menu and real systemd boot-time mask generation."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

package, output = map(Path, sys.argv[1:])
output.mkdir()
subprocess.run(["sha256sum", "--strict", "-c", "SHA256SUMS"], cwd=package, check=True)
base = (package / "base-menu").read_text()
trial = (package / "trial-menu").read_text()
assert trial.startswith(base)


def entry(menu, name):
    found = re.findall(r"^menuentry '[^\n]*' --id " + name + r" \{.*?^\}", menu, re.M | re.S)
    assert len(found) == 1, name
    return found[0]


def args(block):
    lines = [line for line in block.splitlines() if line.strip().startswith("bt_enable_boot ")]
    assert len(lines) == 1
    return shlex.split(lines[0])[1:]


normal = args(entry(base, "latest-media"))
passive = args(entry(trial, "passive-charge"))
assert entry(base, "latest-media") == entry(trial, "latest-media")
required = {
    "np545-gpiocharge.service", "np545-charge-keepalive.service",
    "np545-pd-hotplug.service", "np545-ic10-irq.service", "np545-irq-ack.service",
    "np545-charge-sleep.service", "np545-charge-sleep-guard.service",
    "np545-charge-observe.service", "np545-power-supply.service",
    "np545-battery-sample.service",
}
assert {a.split("=", 1)[1] for a in passive if a.startswith("systemd.mask=")} == required
assert "np545.battery=1" in passive and "np545.chargepassive=1" in passive
assert not any(a.startswith(("np545.gpiocharge=", "np545.chargestartup=", "np545.hotplug=",
                            "np545.keepcharge=", "np545.ic10irq=", "np545.irqack=")) for a in passive)
assert len(" ".join(passive)) < 1700
removed = set(normal) - set(passive)
assert removed == {"np545.gpiocharge=1", "np545.chargestartup=1",
                   "systemd.wants=np545-gpiocharge.service", "systemd.wants=np545-battery-sample.service"}
generator = "/usr/lib/systemd/system-generators/systemd-debug-generator"
results = {}
for label, argv in (("latest", normal), ("passive", passive),
                    ("passive-with-unwanted-controller-request", passive + ["systemd.wants=np545-gpiocharge.service"])):
    destination = output / label
    directories = [destination / p for p in ("normal", "early", "late")]
    for directory in directories:
        directory.mkdir(parents=True)
    env = os.environ.copy()
    env["SYSTEMD_PROC_CMDLINE"] = " ".join(argv)
    env["SYSTEMD_IN_INITRD"] = "0"
    subprocess.run([generator, *map(str, directories)], env=env, check=True)
    masks = {p.name for p in directories[1].iterdir() if p.is_symlink() and os.readlink(p) == "/dev/null"}
    wants = {p.name for p in directories[1].glob("*.wants/*")}
    if label == "latest":
        assert not masks
        assert "np545-gpiocharge.service" in wants
        assert "np545-passive-battery-sample.service" not in wants
    else:
        assert masks == required, masks
        assert "np545-passive-battery-sample.service" in wants
    results[label] = {"masks": sorted(masks), "wants": sorted(wants)}
(output / "result.json").write_text(json.dumps({
    "passed": True, "old_menu_byte_preserved": True, "unchanged_latest_entry": True,
    "generator_cases": results,
    "limit": "Real systemd generator and menu validation; physical boot is still required.",
}, indent=2) + "\n")
print("PASS: unchanged Latest and all 10 runtime masks, including an unwanted controller request")

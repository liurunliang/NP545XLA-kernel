#!/usr/bin/env python3
"""Append a passive charging experiment to the captured NP545XLA GRUB menu."""
import hashlib
import json
from pathlib import Path
import re
import shlex
import sys

BASE_EFI = "0fb029e284fbc612e41cfcab8b45fd8da37dda4a01f35951b6a1258adda94d29"
IMAGE = "163b71d2e6ae7deb2e0500de71d2b4639f1da80c68edb81a3477d1551e64735b"
DT = "2661562ea2c05e2548a1cbb74cf0c70996d0aa31c9d9ce03c94225f9c51a1a25"
MASKS = (
    "np545-gpiocharge.service", "np545-charge-keepalive.service",
    "np545-pd-hotplug.service", "np545-ic10-irq.service", "np545-irq-ack.service",
    "np545-charge-sleep.service", "np545-charge-sleep-guard.service",
    "np545-charge-observe.service", "np545-power-supply.service",
    "np545-battery-sample.service",
)
LOGGER = "np545-passive-battery-sample.service"


def generate(base):
    if "passive-charge" in base or "np545_passive_once" in base:
        raise ValueError("passive entry already present")
    entries = re.findall(r"^menuentry '[^\n]*' --id latest-media \{.*?^\}", base,
                         re.M | re.S)
    if len(entries) != 1:
        raise ValueError("expected one original Latest entry")
    original = entries[0]
    lines = [line for line in original.splitlines() if line.strip().startswith("bt_enable_boot ")]
    if len(lines) != 1:
        raise ValueError("unexpected Latest kernel handoff")
    tokens = shlex.split(lines[0])
    remove = {"np545.gpiocharge=1", "np545.chargestartup=1",
              "systemd.wants=np545-gpiocharge.service",
              "systemd.wants=np545-battery-sample.service"}
    if not remove <= set(tokens) or "np545.battery=1" not in tokens:
        raise ValueError("unexpected original charging flags")
    args = [token for token in tokens[1:] if token not in remove]
    forbidden = ("np545.gpiocharge=", "np545.chargestartup=", "np545.keepcharge=",
                 "np545.hotplug=", "np545.ic10irq=", "np545.irqack=")
    if any(token.startswith(forbidden) for token in args):
        raise ValueError("unexpected charging activation argument")
    args += ["np545.chargepassive=1", f"systemd.wants={LOGGER}"]
    args += [f"systemd.mask={unit}" for unit in MASKS]
    # The handoff adds BOOT_IMAGE, rdinit and firmware path before these arguments.
    if len(" ".join(args).encode()) > 1700:
        raise ValueError("insufficient ARM64 command-line headroom")
    trial = original.replace(
        "Debian 13 - Latest (Samsung)' --id latest-media",
        "Debian 13 - Firmware charging, no Linux control (Samsung)' --id passive-charge")
    trial = trial.replace("set diag_entry=Debian-latest-media", "set diag_entry=Debian-passive-charge")
    trial = trial.replace(lines[0], "        bt_enable_boot " + " ".join(args))
    if "--id passive-charge" not in trial:
        raise ValueError("unexpected original menu title")
    once = '''
if search --no-floppy --file --set=passive_esp /boot/np545-passive.env; then
    set passive_env="(${passive_esp})/boot/np545-passive.env"
    load_env --file "$passive_env" np545_passive_once
    if [ "$np545_passive_once" = 1 ]; then
        set np545_passive_once=0
        if save_env --file "$passive_env" np545_passive_once; then set default=passive-charge; fi
    fi
fi
'''
    return base + "\n" + trial + "\n" + once, args


def main():
    directory = Path(sys.argv[1])
    if hashlib.sha256((directory / "original.EFI").read_bytes()).hexdigest() != BASE_EFI:
        raise ValueError("current EFI changed; recapture and review before building")
    base = (directory / "base-menu").read_text()
    trial, args = generate(base)
    (directory / "trial-menu").write_text(trial)
    (directory / "metadata.json").write_text(json.dumps({
        "base_efi": BASE_EFI, "image": IMAGE,
        "image_path": f"/boot/np545xla-bluetooth-enable/Image-{IMAGE}",
        "dt": DT, "dt_path": f"/boot/daily-media-{DT}.dtb",
        "default_preserved": True, "masked_units": MASKS,
        "logger": LOGGER, "kernel_arguments": args,
        "charge_register_writes": False, "sleep_configuration_changed": False,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Sample the Samsung gauge, lid switch and actual kernel suspend time."""
import argparse
import datetime
import errno
import fcntl
import json
from pathlib import Path
import time

SUPPLY = Path("/sys/class/power_supply/np545-battery")


def read_value(path):
    try:
        value = path.read_text().strip()
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ENODATA):
            return None
        raise
    return int(value) if value.lstrip("-").isdigit() else value


def lid_closed():
    for event in Path("/sys/class/input").glob("event*"):
        if (event / "device/name").read_text().strip() == "gpio-keys":
            with (Path("/dev/input") / event.name).open("rb") as stream:
                switches = bytearray(8)
                fcntl.ioctl(stream, 0x8008451B, switches, True)
                return bool(switches[0] & 1)
    return None


def sample(event):
    record = dict(event=event, utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  boot_id=Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                  boottime=time.clock_gettime(time.CLOCK_BOOTTIME),
                  monotonic=time.monotonic())
    if SUPPLY.exists():
        for prop in ("status", "capacity", "current_now", "voltage_now", "charge_now",
                     "charge_full", "energy_now", "energy_full"):
            try:
                record[prop] = read_value(SUPPLY / prop)
            except OSError as exc:
                record[prop + "_error"] = exc.errno
    else:
        record["error"] = "gauge unavailable"
    record["suspend_success"] = read_value(Path("/sys/power/suspend_stats/success"))
    record["suspend_fail"] = read_value(Path("/sys/power/suspend_stats/fail"))
    try:
        record["lid_closed"] = lid_closed()
    except OSError:
        record["lid_closed"] = None
    print(json.dumps(record, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--event", choices=("sample", "pre", "post"), default="sample")
    args = parser.parse_args()
    if "np545.battery=1" not in Path("/proc/cmdline").read_text().split():
        parser.error("select the read-only battery test entry")
    while True:
        sample(args.event)
        if not args.watch:
            break
        time.sleep(5)

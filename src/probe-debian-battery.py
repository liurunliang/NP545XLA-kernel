#!/usr/bin/env python3
"""Sample the Samsung gauge, lid switch and actual kernel suspend time."""
import argparse
import datetime
import errno
import fcntl
import json
import sys
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


def sleep_result(before, after):
    # Wall time includes NTP adjustments. These two kernel clocks exclude that error.
    window_s = after["boottime"] - before["boottime"]
    suspended_s = window_s - (after["monotonic"] - before["monotonic"])
    if suspended_s <= 0 or after["suspend_success"] != before["suspend_success"] + 1:
        raise ValueError("the pair does not cover one successful suspend")
    if after["suspend_fail"] != before["suspend_fail"] or before["lid_closed"] is not True:
        raise ValueError("suspend failure or no pre-suspend closed lid")
    if any((row.get("current_now") is None or row["current_now"] >= 0) for row in (before, after)):
        raise ValueError("both endpoints must show battery discharge")
    result = dict(boot_id=before["boot_id"], start_utc=before["utc"], end_utc=after["utc"],
                  suspended_s=round(suspended_s, 3), awake_overhead_s=round(window_s-suspended_s, 3),
                  percent_before=before["capacity"], percent_after=after["capacity"])
    if before.get("energy_now") is not None and after.get("energy_now") is not None:
        wh = (before["energy_now"] - after["energy_now"]) / 1e6
        result["basis"] = "native remaining energy"
    elif all(row.get("charge_now") is not None and row.get("voltage_now") for row in (before, after)):
        delta_mah = (before["charge_now"] - after["charge_now"]) / 1000
        volts = (before["voltage_now"] + after["voltage_now"]) / 2e6
        wh = delta_mah * volts / 1000
        result.update(delta_mAh=delta_mah, mean_endpoint_V=volts, basis="charge difference at mean voltage")
    else:
        raise ValueError("missing or incompatible native gauge units")
    if wh < 0:
        raise ValueError("remaining capacity increased across this window")
    result["estimated_Wh"] = round(wh, 5)
    # Capacity brackets both hooks, including their small amount of awake time.
    result["window_mean_W"] = round(wh * 3600 / window_s, 4)
    return result


def summarize(lines):
    before = None
    pairs = 0
    for line in lines:
        if not line.strip():
            continue
        row = json.loads(line)
        if row["event"] == "pre":
            before = row
        elif row["event"] == "post":
            if before is None or before["boot_id"] != row["boot_id"]:
                raise ValueError("post without matching pre from this boot")
            print(json.dumps(sleep_result(before, row)))
            before = None
            pairs += 1
    if before is not None or not pairs:
        raise ValueError("no complete sleep interval")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--watch", action="store_true")
    group.add_argument("--summarize-sleep", action="store_true", help="read journal JSON lines from stdin")
    parser.add_argument("--event", choices=("sample", "pre", "post"), default="sample")
    args = parser.parse_args()
    if args.summarize_sleep:
        try:
            summarize(sys.stdin)
        except (ValueError, KeyError, TypeError) as exc:
            parser.exit(1, f"{exc}\n")
        sys.exit(0)
    if "np545.battery=1" not in Path("/proc/cmdline").read_text().split():
        parser.error("select the read-only battery test entry")
    while True:
        sample(args.event)
        if not args.watch:
            break
        time.sleep(5)

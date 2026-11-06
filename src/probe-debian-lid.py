#!/usr/bin/env python3
"""Observe GPIO50, its IRQ, SW_LID and actual suspend time on the Samsung NP545XLA."""
import argparse
import array
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import select
import struct
import time


def snapshot(device):
    gpio = re.search(r"^\s*gpio50\s*:\s*in\s+(high|low)\b",
                     Path("/sys/kernel/debug/gpio").read_text(), re.M)
    irq, = [line for line in Path("/proc/interrupts").read_text().splitlines()
            if re.search(r"\bmsmgpio\s+50\s+Edge\s+gpio_keys\b", line)]
    counts = irq.split("msmgpio", 1)[0].split(":", 1)[1].split()
    switches = bytearray(8)
    fcntl.ioctl(device, 0x8008451B, switches, True)  # EVIOCGSW(8)
    return dict(gpio=gpio[1], irq_count=sum(map(int, counts)), sw_lid=switches[0] & 1,
                success=int(Path("/sys/power/suspend_stats/success").read_text()),
                fail=int(Path("/sys/power/suspend_stats/fail").read_text()))


def emit(**fields):
    boot = time.clock_gettime(time.CLOCK_BOOTTIME)
    print(json.dumps(dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds"),
                          boot_s=round(boot, 3), sleep_s=round(boot - time.monotonic(), 3), **fields)),
          flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=900, help="elapsed capture duration, including sleep")
    args = parser.parse_args()
    if args.seconds < 1 or os.geteuid() != 0:
        parser.error("run as root with a positive capture duration")
    if b"samsung,np545xla" not in Path("/proc/device-tree/compatible").read_bytes().split(b"\0"):
        parser.error("requires the Samsung NP545XLA")
    nodes = [p for p in Path("/sys/class/input").glob("event*")
             if (p / "device/name").read_text().strip() == "gpio-keys" and
             int((p / "device/capabilities/sw").read_text().split()[-1], 16) & 1]
    if len(nodes) != 1:
        parser.error(f"expected one gpio-keys SW_LID device, found {nodes}")
    wake_registers = Path("/sys/kernel/debug/np545_lid_irq")
    record = struct.Struct("@llHHi")  # Linux arm64 struct input_event
    deadline = time.clock_gettime(time.CLOCK_BOOTTIME) + args.seconds
    with open(Path("/dev/input") / nodes[0].name, "rb", buffering=0) as device:
        fcntl.ioctl(device, 0x400445A0, array.array("i", [time.CLOCK_BOOTTIME]))  # EVIOCSCLOCKID
        emit(device=device.name, boot_id=Path("/proc/sys/kernel/random/boot_id").read_text().strip())
        prev, heartbeat = None, 0.
        while (left := deadline - time.clock_gettime(time.CLOCK_BOOTTIME)) > 0:
            current = snapshot(device)
            now = time.monotonic()
            # Repeated samples while closed distinguish early resume from opening the lid.
            if current != prev or (current["gpio"] == "low" and now >= heartbeat):
                if wake_registers.is_file():
                    emit(**current, pdc=wake_registers.read_text().strip())
                else:
                    emit(**current)
                prev, heartbeat = current, now + 2
            if select.select([device], [], [], min(.4, left))[0]:
                sec, usec, kind, code, value = record.unpack(device.read(record.size))
                if (kind, code) == (5, 0):  # EV_SW / SW_LID only
                    emit(event=value, event_boot_s=round(sec + usec / 1e6, 6))


if __name__ == "__main__":
    main()

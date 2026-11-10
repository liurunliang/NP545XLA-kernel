#!/usr/bin/python3
"""Continue only a charge that the NP545XLA firmware started on IC10."""
import ctypes as C
import fcntl
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time

from np545_charge_observe import BATTERY, DT, Message, Registers, Transfer, port

CAP_MA = 1024
FIRMWARE_MA = 3776
FIRMWARE_MV = 8760
stopping = threading.Event()


def uptime():
    return time.clock_gettime(time.CLOCK_BOOTTIME)


class StopCharge(Exception):
    pass


class FullCharge(StopCharge):
    """A normal full-pack stop; legacy callers still stop as before."""


def full_status(battery):
    flags = battery["flags"]
    # Initialized + full; termination and not-charging are allowed only here.
    return flags & 0xa0 == 0xa0 and not flags & 0x9b0f


class Charger(Registers):
    open_flags = os.O_RDWR

    def __init__(self):
        super().__init__("ic20", 0x09)

    def identify(self):
        if (self.word(0xfe), self.word(0xff)) != (0x0040, 0x0089):
            raise StopCharge("unexpected BQ25710 identity")

    def set_current(self, ma):
        if not 0 <= ma <= CAP_MA or ma % 64:
            raise ValueError("invalid charge target")
        self.identify()
        # TI ChargeCurrent is a little-endian word. This is the only data write.
        data = (C.c_uint8 * 3)(0x14, ma & 255, ma >> 8)
        msg = (Message * 1)(Message(self.address, 0, len(data), data))
        if fcntl.ioctl(self.fd, 0x0707, Transfer(msg, 1)) != 1 or self.word(0x14) != ma:
            raise OSError("ChargeCurrent write or readback failed")


def pack():
    names = ("temp", "current_now", "voltage_now", "charge_now", "capacity",
             "constant_charge_current_max", "constant_charge_voltage_max")
    data = {name: int((BATTERY / name).read_text()) for name in names}
    data["flags"] = int((BATTERY / "device/sbs_status").read_text(), 0)
    return data


def target(pd, battery, chip, expected):
    if (pd.get("requested_mV"), pd.get("requested_mA")) != (12000, 3000):
        raise StopCharge("IC10 lost the verified 12 V / 3 A contract")
    chip.identify()
    # Preserve the firmware voltage, 175 s watchdog, IDPM and input limit.
    if (chip.word(0x12) != 0xe70e or chip.word(0x15) != FIRMWARE_MV
            or chip.word(0x22) != 0x3c00 or chip.word(0x3f) != 0x3c00
            or chip.word(0x14) != expected):
        raise StopCharge("charger settings changed or charging has stopped")
    return pack_target(battery)


def pack_target(battery, *, starting=False):
    flags = battery["flags"]
    # SBS initialized, no alarms or error, neither full nor discharging.
    blocked = 0xdb2f if starting else 0xdb6f
    if not flags & 0x80 or flags & blocked:
        if full_status(battery):
            raise FullCharge(f"pack status {flags:#06x}")
        raise StopCharge(f"pack status {flags:#06x}")
    if not 50 <= battery["temp"] <= 400 or not 0 <= battery["capacity"] < 100:
        raise StopCharge("pack temperature or state of charge out of range")
    if not (FIRMWARE_MV * 1000 <= battery["constant_charge_voltage_max"] <= 8900000
            and 6000000 <= battery["voltage_now"] <= FIRMWARE_MV * 1000):
        raise StopCharge("pack voltage or requested voltage out of range")
    request = battery["constant_charge_current_max"]
    if not 64000 <= request <= 65534000 or (not starting and battery["current_now"] <= 0):
        raise StopCharge("pack has stopped requesting or accepting charge")
    return min(CAP_MA, request // 1000) // 64 * 64


def log(event, **data):
    print(json.dumps(dict(event=event, boottime=round(uptime(), 3), **data)), flush=True)


def run():
    args = Path("/proc/cmdline").read_text().split()
    if not ({"np545.keepcharge=1", "np545.battery=1"} <= set(args)
            and b"samsung,np545xla" in (DT / "compatible").read_bytes().split(b"\0")):
        raise StopCharge("select the NP545XLA keepalive trial")
    # sysfs is published after the read-only gauge finishes probing.
    while not (BATTERY / "device/sbs_status").exists() and uptime() < 90:
        if stopping.wait(1):
            return
    if uptime() >= 90:
        raise StopCharge("firmware handoff window has elapsed")
    with Charger() as chip:
        last_write = None
        expected = FIRMWARE_MA
        try:
            while not stopping.is_set():
                battery = pack()
                ma = target(port("ic10"), battery, chip, expected)
                now = uptime()
                if last_write is None:
                    if now >= 90:
                        raise StopCharge("late firmware handoff")
                    # Make this handoff one-shot, including failures after the first write.
                    with Path("/run/np545-keepcharge.claimed").open("x") as claim:
                        claim.write(f"{now:.3f}\n")
                elif now - last_write > 90:
                    raise StopCharge("refresh deadline missed")
                if stopping.is_set():
                    break
                if last_write is None or now - last_write >= 45 or ma != expected:
                    last_write = now  # also clean up if the readback after writing fails
                    chip.set_current(ma)
                    log("refresh", previous_mA=expected, readback_mA=ma, **battery)
                    expected = ma
                stopping.wait(2)
        finally:
            if last_write is not None:
                chip.set_current(0)
                log("stop", readback_mA=0)


if __name__ == "__main__":
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopping.set())
    try:
        run()
    except (StopCharge, OSError, ValueError) as exc:
        log("exit", reason=str(exc))
        sys.exit(1)

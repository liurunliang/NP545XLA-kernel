#!/usr/bin/env python3
"""Observe both Samsung PD ports, the charger and the battery; transmit register selectors only."""
import argparse
import ctypes as C
import datetime
import fcntl
import json
import os
from pathlib import Path
import time

DT = Path("/sys/firmware/devicetree/base")
BATTERY = Path("/sys/class/power_supply/np545-battery")
BUSES = {"ic10": "ac0000/a84000", "ic19": "cc0000/c84000", "ic20": "cc0000/c88000"}
# No command, interrupt or read-to-clear registers. Values specify exact permitted read lengths.
PD_REGS = {0x0020: 4, 0x0240: 8, 0x0260: 32}
BQ_REGS = {reg: 2 for reg in (0xfe, 0xff, 0x12, 0x14, 0x15, 0x22, 0x3f, 0x35, 0x23)}


class Message(C.Structure):
    _fields_ = [("address", C.c_uint16), ("flags", C.c_uint16), ("length", C.c_uint16),
                ("buffer", C.POINTER(C.c_uint8))]


class Transfer(C.Structure):
    _fields_ = [("messages", C.POINTER(Message)), ("count", C.c_uint32)]


def adapter(label):
    parent, addr = BUSES[label].split("/")
    node = DT / f"soc@0/geniqup@{parent}/i2c@{addr}"
    for bus in Path("/sys/bus/i2c/devices").glob("i2c-*"):
        if (bus / "of_node").resolve() == node.resolve():
            return bus.name
    raise OSError(f"{label} adapter not registered")


class Registers:
    def __init__(self, label, address):
        if (label, address) not in (("ic10", 0x33), ("ic19", 0x33), ("ic20", 0x09)):
            raise ValueError("unknown board endpoint")
        self.address = address
        self.fd = os.open("/dev/" + adapter(label), os.O_RDONLY | os.O_CLOEXEC)
        try:
            # Refuse a kernel-owned address; never force access.
            fcntl.ioctl(self.fd, 0x0703, address)
        except BaseException:
            os.close(self.fd)
            raise

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        os.close(self.fd)

    def read(self, register):
        pd = self.address == 0x33
        length = (PD_REGS if pd else BQ_REGS)[register]
        index = register.to_bytes(2 if pd else 1, "big")
        select = (C.c_uint8 * len(index)).from_buffer_copy(index)
        data = (C.c_uint8 * length)()
        # A repeated START separates the register pointer from the read. No register data is written.
        msgs = (Message * 2)(Message(self.address, 0, len(index), select),
                             Message(self.address, 1, length, data))
        if fcntl.ioctl(self.fd, 0x0707, Transfer(msgs, 2)) != 2:
            raise OSError("incomplete I2C read")
        return bytes(data)

    def word(self, register):
        return int.from_bytes(self.read(register), "little")


def port(label):
    with Registers(label, 0x33) as chip:
        state = chip.word(0x0020)
        caps = chip.read(0x0260)
        req = chip.read(0x0240)
        end = chip.word(0x0020)
    header = int.from_bytes(caps[:2], "little")
    req_header = int.from_bytes(req[:2], "little")
    rdo = int.from_bytes(req[4:8], "little")
    index = (rdo >> 28) & 7
    count = (header >> 12) & 7
    data = dict(state_hex=f"{state:08x}", pd_state=state & 255, attached=bool(state & (1 << 24)),
                source=bool(state & (1 << 25)), caps_hex=caps.hex(), request_hex=req.hex(),
                stable_state=state == end)
    # Detached ports may retain old messages. Interpret only a live, stable Sink_Ready.
    if (state == end and data["pd_state"] == 21 and data["attached"] and not data["source"]
            and header & 31 == 1 and req_header & 31 == 2 and (req_header >> 12) & 7 == 1
            and 1 <= index <= count):
        pdo = int.from_bytes(caps[4 * index:4 * index + 4], "little")
        if pdo >> 30 == 0:
            data.update(selected_pdo=index, requested_mV=((pdo >> 10) & 1023) * 50,
                        requested_mA=((rdo >> 10) & 1023) * 10)
    return data


def charger():
    with Registers("ic20", 0x09) as chip:
        vendor, part = chip.word(0xfe), chip.word(0xff)
        if (vendor, part) != (0x40, 0x89):
            return dict(manufacturer=vendor, part=part, error="unexpected charger ID")
        raw = {r: chip.word(r) for r in (0x12, 0x14, 0x15, 0x22, 0x3f, 0x35, 0x23)}
    return dict(manufacturer=vendor, part=part, raw={f"{r:02x}":v for r, v in raw.items()},
                watchdog_s=(0, 5, 88, 175)[(raw[0x12] >> 13) & 3], inhibit=bool(raw[0x12] & 1),
                current_setting_mA=raw[0x14] & 0x1fc0, voltage_setting_mV=raw[0x15] & 0x7ff0,
                input_limit_code=(raw[0x22] >> 8) & 127,
                vbus_adc_continuous=bool(raw[0x35] & 0x8000 and raw[0x35] & 0x40 and not raw[0x12] & 0x8000))


def sample():
    stamp = time.clock_gettime(time.CLOCK_BOOTTIME)
    data = dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                boot_id=Path("/proc/sys/kernel/random/boot_id").read_text().strip(), boottime=stamp)
    for label, reader in (("ic10", lambda: port("ic10")), ("ic19", lambda: port("ic19")),
                          ("charger", charger)):
        try:
            data[label] = reader()
        except OSError as exc:
            data[label] = {"error": str(exc)}
    battery = {}
    for name in ("status", "capacity", "voltage_now", "current_now", "charge_now",
                 "constant_charge_current_max", "constant_charge_voltage_max"):
        try:
            value = (BATTERY / name).read_text().strip()
            battery[name] = value if name == "status" else int(value)
        except OSError as exc:
            battery[name + "_error"] = exc.errno
    data["battery"] = battery
    data["sample_s"] = round(time.clock_gettime(time.CLOCK_BOOTTIME) - stamp, 4)
    print(json.dumps(data, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--watch", action="store_true")
    args = parser.parse_args()
    if ("np545.battery=1" not in Path("/proc/cmdline").read_text().split()
            or b"samsung,np545xla" not in (DT / "compatible").read_bytes().split(b"\0")):
        parser.error("select the Samsung read-only battery trial")
    while True:
        sample()
        if not args.watch:
            break
        time.sleep(2)

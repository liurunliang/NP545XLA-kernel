#!/usr/bin/python3
"""Recover a physical IC10 detach / reattach in the dedicated NP545XLA USB trial."""
from contextlib import contextmanager
import ctypes as C
import errno
import fcntl
import os
from pathlib import Path
import signal
import sys
import time

from keepcharge import (Charger, FIRMWARE_MA, FIRMWARE_MV, StopCharge, log, pack, pack_target,
                        stopping, uptime)
from np545_charge_observe import BATTERY, DT, Message, Registers, Transfer, port

# Measured firmware presets: unplugged boot and the original powered handoff.
FIRMWARE_CHARGE = {8696: 2880, FIRMWARE_MV: FIRMWARE_MA}


def send(chip, payload):
    data = (C.c_uint8 * len(payload)).from_buffer_copy(payload)
    msg = (Message * 1)(Message(chip.address, 0, len(data), data))
    if fcntl.ioctl(chip.fd, 0x0707, Transfer(msg, 1)) != 1:
        raise OSError("incomplete I2C transfer")


@contextmanager
def pd_mailbox(chip):
    # One IC10 writer at a time, including its command response in register 0x14.
    # Both services open the same I2C device inode with independent file handles.
    fcntl.flock(chip.fd, fcntl.LOCK_EX)
    try:
        yield
    finally:
        fcntl.flock(chip.fd, fcntl.LOCK_UN)


# /run is per boot. The ACK test publishes only a status captured before clearing
# GPIO101, since a detached IC10 may sleep and NACK subsequent polls.
ACK_DETACH = Path("/run/np545-irq-ack-detach")


def idle_sink(state):
    return state & 0xff == 0 and not (state & 0xe2000000)


def profile(pd):
    """Position and exact fixed 12 V / 3 A PDO from this live Source_Capabilities."""
    if not pd.get("requested_mV") or int(pd["state_hex"], 16) & 0xe0000000:
        raise StopCharge("unstable sink, short or reset")
    caps = bytes.fromhex(pd["caps_hex"])
    header = int.from_bytes(caps[:2], "little")
    if len(caps) != 32 or header & 0x801f != 1:
        raise StopCharge("invalid source capabilities")
    for i in range(1, ((header >> 12) & 7) + 1):
        pdo = int.from_bytes(caps[4*i:4*i+4], "little")
        if pdo >> 30 == 0 and (pdo >> 10) & 1023 == 240 and pdo & 1023 == 300:
            return i, pdo
    raise StopCharge("source does not offer fixed 12 V / 3 A")


class Sink(Registers):
    open_flags = os.O_RDWR
    pd_regs = {**Registers.pd_regs, 0x60: 4, 0x14: 4}

    def __init__(self):
        super().__init__("ic10", 0x33)

    def check(self, known, voltage, *, allow_detach=False):
        try:
            pd = port("ic10")
        except OSError as exc:
            if allow_detach and exc.errno in (errno.ENXIO, errno.EREMOTEIO):
                return None
            raise
        state = int(pd["state_hex"], 16)
        if allow_detach and not state & 0xe2000000 and (idle_sink(state) or not pd.get("requested_mV")):
            return None
        if (profile(pd) != known or pd["requested_mV"] != voltage or pd["requested_mA"] != 3000
                or (voltage == 12000 and pd["selected_pdo"] != known[0])):
            raise StopCharge("source, selected contract or role changed")
        lp = self.word(0x60)
        end = self.word(0x20)
        if allow_detach and idle_sink(end) and not lp & 0x48:
            return None
        if lp & 0x48 or lp & 0xa0 != 0xa0 or end != int(pd["state_hex"], 16):
            raise StopCharge(f"port not safely attached and dry (LP={lp:#010x})")
        return pd

    def select(self, known):
        with pd_mailbox(self):
            self.check(known, 5000)
            # Samsung EmuEC: select PDO then enter PE_SNK_Select_Capability.
            send(self, bytes([0, 0x10, 3, 3, known[0]]))
            self.check(known, 5000)
            send(self, bytes([0, 0x10, 3, 2, 19]))

    def switches(self):
        with pd_mailbox(self):
            return self._switches_locked()

    def _switches_locked(self):
        send(self, bytes.fromhex("00 10 03 92"))
        time.sleep(0.02)
        data = self.read(0x14)
        if data[0] != 0 or data[1] not in (0, 1):
            raise StopCharge(f"unexpected provider/consumer status: {data.hex()}")
        return data[1]

    def consumer(self, on):
        # Same board's consumer-only command. Provider and discharge are both off.
        with pd_mailbox(self):
            send(self, bytes([0, 0x10, 3, 0x91, 0, int(on), 0, 2 * int(on)]))
            time.sleep(0.05)
            if self._switches_locked() != int(on):
                raise StopCharge("consumer switch readback mismatch")


class InputCharger(Charger):
    bq_regs = {**Charger.bq_regs, 0x20: 2}

    def input_present(self):
        self.identify()
        status = self.word(0x20)
        # Reading ChargerStatus acknowledges some fault flags. Any reported fault
        # ends this trial instead of clearing it in a polling/retry loop.
        if status & 0x21ff:
            raise StopCharge(f"BQ fault, VAP or OTG: {status:#06x}")
        return bool(status & 0x8000)

    def settings(self, expected, *, voltage=FIRMWARE_MV):
        # 8400 mV is accepted only for a zero-current input-only state. Active
        # charging uses one of the two measured firmware voltage ceilings.
        if voltage not in (8400, *FIRMWARE_CHARGE) or (voltage == 8400 and expected):
            raise StopCharge("unsupported voltage and charge target")
        self.identify()
        if (self.word(0x12), self.word(0x15), self.word(0x14)) != (0xe70e, voltage, expected):
            raise StopCharge("charger option, pack voltage limit or charge target changed")

    def limit_input(self, *, voltage=FIRMWARE_MV):
        self.settings(0, voltage=voltage)
        host = self.word(0x3f)
        # Callers have verified a live 3 A contract before changing an
        # observed USB (450 mA) or reset (3250 mA) limit to the board's 3 A limit.
        if host in (0x0900, 0x4100):
            send(self, bytes.fromhex("3f 00 3c"))
            time.sleep(0.05)
        self.check_limits()

    def check_limits(self):
        if self.word(0x3f) != 0x3c00 or self.word(0x22) != 0x3c00:
            raise StopCharge("input limits do not match the verified 3 A profile")

    def restore_firmware_voltage(self):
        # BQ25710's 2S reset value is 8400 mV. Restore only this board's measured
        # 8760 mV ceiling, while charging is stopped; callers must validate the
        # live pack request and IC10 contract first. Never expose an arbitrary
        # voltage setter or alter the watchdog/options.
        self.settings(0, voltage=8400)
        send(self, bytes([0x15, FIRMWARE_MV & 255, FIRMWARE_MV >> 8]))
        self.settings(0)


def wait_for(description, reader, seconds, delay=0.5):
    until = uptime() + seconds
    while uptime() < until and not stopping.is_set():
        value = reader()
        if value:
            return value
        stopping.wait(delay)
    raise StopCharge("stopped or timed out waiting for " + description)


def poll_port():
    try:
        return port("ic10")
    except OSError as exc:
        # A sleeping controller can NACK while physically detached. Only an
        # explicit detached status plus discharging can qualify a disconnect.
        if exc.errno in (errno.ENXIO, errno.EREMOTEIO):
            return {}
        raise


def is_detached(pd):
    return (pd.get("stable_state") and pd["pd_state"] == 0 and not pd["attached"]
            and not pd["source"])


def detached_since(since, use_ack):
    pd = poll_port()
    confirmed = is_detached(pd)
    if not confirmed and use_ack and (not pd or idle_sink(int(pd["state_hex"], 16))):
        try:
            stamp, state = map(int, ACK_DETACH.read_text().split())
        except FileNotFoundError:
            return False
        confirmed = (since < stamp <= time.clock_gettime_ns(time.CLOCK_BOOTTIME)
                     and idle_sink(state) and not state & (1 << 24))
    return confirmed and pack()["current_now"] < 0


def contract(voltage):
    pd = poll_port()
    return pd if pd.get("requested_mV") == voltage and pd.get("requested_mA") == 3000 else None


def charge_after_replug(sink, chip, known, wait=None, *, initial_current=0, voltage=FIRMWARE_MV):
    # The startup policy can also take over the measured firmware-started
    # charge. All other callers still require a zero target after a replug.
    if voltage not in FIRMWARE_CHARGE or initial_current not in (0, FIRMWARE_CHARGE[voltage]):
        raise StopCharge("unknown initial charge target")
    if wait is None:
        wait = stopping.wait
    switch_owned = False
    charge_owned = False
    try:
        sink.check(known, 12000)
        pack_target(pack(), starting=initial_current == 0)
        chip.settings(initial_current, voltage=voltage)
        present = chip.input_present()
        enabled = sink.switches()
        log("input-before", ac=present, consumer=enabled)
        if initial_current and (not present or not enabled):
            raise StopCharge("firmware charge has no verified input path")
        if not enabled:
            if present:
                raise StopCharge("BQ already supplied through a different path")
            chip.limit_input(voltage=voltage)
            sink.check(known, 12000)
            switch_owned = True
            sink.consumer(True)
        wait_for("BQ adapter present", chip.input_present, 4)
        if initial_current:
            chip.check_limits()
        else:
            chip.limit_input(voltage=voltage)
        expected = initial_current
        last = None
        positive = False
        while not stopping.is_set():
            try:
                if sink.check(known, 12000, allow_detach=True) is None:
                    return
            except OSError as exc:
                if exc.errno in (errno.ENXIO, errno.EREMOTEIO):
                    return
                raise
            if not chip.input_present():
                return  # stop; only a confirmed detach can arm the next connection
            chip.settings(expected, voltage=voltage)
            chip.check_limits()
            battery = pack()
            now = uptime()
            if last is not None and now - last > 90:
                raise StopCharge("refresh deadline missed")
            if not positive and last is not None:
                positive = battery["current_now"] > 0
                if not positive and now - began >= 10:
                    raise StopCharge("pack did not begin taking current")
            ma = pack_target(battery, starting=not positive)
            if last is None or now-last >= 45 or expected != ma:
                if stopping.is_set():
                    return
                charge_owned = True
                chip.set_current(ma)
                if last is None:
                    began = now
                log("refresh", ac=True, readback_mA=ma, **battery)
                expected, last = ma, now
            if wait(1):
                return
    finally:
        try:
            if charge_owned:
                chip.set_current(0)
                log("stop", readback_mA=0)
        finally:
            # Never send a switch command to a port which has changed roles.
            pd = poll_port() if switch_owned else {}
            if pd.get("attached") and pd.get("pd_state") != 0 and not pd["source"]:
                sink.consumer(False)
                log("consumer-off")


def boot_profile():
    wait_for("SBS gauge", lambda: (BATTERY / "device/sbs_status").exists(), 60)
    initial = wait_for("original 12 V source", lambda: contract(12000), 40)
    return profile(initial)


def check_boot_input(sink, chip, known):
    sink.check(known, 12000)
    present, consumer = chip.input_present(), sink.switches()
    if not present or not consumer:
        raise StopCharge(f"unexpected boot path: AC={present}, consumer={consumer}")
    if chip.word(0x14) not in (0, FIRMWARE_MA):
        raise StopCharge("unknown firmware charge target")
    log("ready-for-detach", pdo=known[0], ac=present, consumer=consumer, **pack())


def run():
    args = Path("/proc/cmdline").read_text().split()
    if (not {"np545.hotplug=1", "np545.battery=1"} <= set(args) or "np545.keepcharge=1" in args
            or b"samsung,np545xla" not in (DT / "compatible").read_bytes().split(b"\0")):
        raise StopCharge("requires the dedicated Samsung hotplug entry")
    with Path("/run/np545-hotplug.claimed").open("x"):
        pass
    known = boot_profile()
    with Sink() as sink, InputCharger() as chip:
        check_boot_input(sink, chip, known)
        connected_at = time.clock_gettime_ns(time.CLOCK_BOOTTIME)
        use_ack = "np545.irqack=1" in args
        while not stopping.is_set():
            wait_for("physical detach", lambda: detached_since(connected_at, use_ack), 1800)
            if chip.word(0x14) == FIRMWARE_MA and not chip.input_present():
                chip.set_current(0)
            log("detached", **pack())
            # A fresh connection may select 12 V autonomously or start at 5 V.
            new = wait_for("reattach", lambda: contract(5000) or contract(12000), 1800)
            if profile(new) != known:
                raise StopCharge("advertised 12 V PDO changed")
            connected_at = time.clock_gettime_ns(time.CLOCK_BOOTTIME)
            log("reattached", pd=new)
            if new["requested_mV"] == 5000:
                sink.select(known)
                log("requested-12V", pdo=known[0])
            wait_for("12 V Sink_Ready", lambda: contract(12000), 10)
            if stopping.wait(0.5):
                return
            pd = sink.check(known, 12000)
            log("contract-12V", pd=pd)
            charge_after_replug(sink, chip, known)


if __name__ == "__main__":
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopping.set())
    try:
        run()
    except (StopCharge, OSError, ValueError) as exc:
        log("exit", reason=str(exc))
        sys.exit(0 if stopping.is_set() else 1)

#!/usr/bin/python3
"""Opt-in IC10 startup policy for the original 12 V / 3 A source."""
from hotplug import (FIRMWARE_CHARGE, FIRMWARE_MV, StopCharge, charge_after_replug, is_detached, log,
                     pack, pack_target, poll_port, profile, stopping, uptime, wait_for)
from keepcharge import full_status

FULL_SAMPLE_SECONDS = 30
RECHARGE_PERCENT = 95


def full_idle(battery):
    # 0x40e0 is the measured full pack: initialized, full, discharging and
    # terminate-charge. Other alarms/errors must not become a normal idle state.
    # The full flag takes precedence even if the pack still advertises a target.
    # FullInput only accepts a zero BQ target; wait_full gates any later restart.
    return full_status(battery)


def wait_full(events, sink, chip, known, *, input_voltage, charge_voltage):
    """Hold zero current; two fresh eligible samples are required for recharge.

    Only the startup candidate calls this. Port IRQs and SIGTERM still interrupt
    the wait immediately; timed samples also handle a pack change with no IRQ.
    """
    next_sample = uptime()
    previous_sample = None
    ready = 0
    log("full-wait", recharge_percent=RECHARGE_PERCENT, sample_seconds=FULL_SAMPLE_SECONDS)
    while not stopping.is_set():
        now = uptime()
        if now < next_sample:
            if events.wait_charging(next_sample - now):
                return False
            continue
        # Failure or a changed path never authorizes an automatic restart.
        sink.check(known, input_voltage)
        chip.settings(0, voltage=charge_voltage)
        chip.check_limits()
        if not chip.input_present() or not sink.switches():
            raise StopCharge("full standby lost the verified input path")
        battery = pack()
        flags = battery["flags"]
        full = full_status(battery)
        if (not flags & 0x80 or flags & 0x9b0f
                or (flags & 0x4000 and not full)):
            raise StopCharge(f"pack fault during full standby: {flags:#06x}")
        if (not 50 <= battery["temp"] <= 400 or not 0 <= battery["capacity"] <= 100
                or not 6000000 <= battery["voltage_now"] <= FIRMWARE_MV * 1000
                or not 0 <= battery["constant_charge_current_max"] <= 65534000
                or (battery["constant_charge_voltage_max"] != 0
                    and not FIRMWARE_MV * 1000 <= battery["constant_charge_voltage_max"] <= 8900000)):
            raise StopCharge("invalid pack reading during full standby")
        if previous_sample is None or now - previous_sample > 90:
            ready = 0
        eligible = (not full and battery["capacity"] <= RECHARGE_PERCENT
                    and battery["constant_charge_current_max"] >= 64000)
        if eligible:
            pack_target(battery, starting=True)
            ready += 1
        else:
            ready = 0
        log("full-sample", eligible_samples=ready, readback_mA=0, **battery)
        if ready >= 2 and not stopping.is_set():
            log("recharge-ready", capacity=battery["capacity"])
            return True
        previous_sample = now
        next_sample = uptime() + FULL_SAMPLE_SECONDS
    return False


def discharging_pack():
    battery = pack()
    return battery if battery["current_now"] < 0 else None


def check_role(pd):
    if pd and (int(pd["state_hex"], 16) & 0xe2000000 or pd.get("source")):
        raise StopCharge("IC10 role, short or reset changed")


def initialize_voltage(sink, chip, known):
    voltage = chip.word(0x15)
    if voltage in FIRMWARE_CHARGE:
        return voltage
    sink.check(known, 12000)
    battery = pack()
    pack_target(battery, starting=True)
    chip.settings(0, voltage=8400)
    if (chip.word(0x3f), chip.word(0x22)) not in ((0x4100, 0x4100), (0x3c00, 0x3c00)):
        raise StopCharge("unknown input limits before voltage initialization")
    if chip.input_present() and not sink.switches():
        raise StopCharge("BQ already supplied through a different path")
    if stopping.is_set():
        return
    chip.restore_firmware_voltage()
    log("voltage-initialized", previous_mV=8400, readback_mV=FIRMWARE_MV,
        charge_target_mA=0, **battery)
    return FIRMWARE_MV


class FullInput:
    """Restore system input with zero charge current; retain the pack voltage."""
    def __init__(self, sink, chip):
        self.sink, self.chip = sink, chip
        self.owned = False
        self.known = None

    def ready(self, known, voltage):
        chip, sink = self.chip, self.sink
        pack_voltage = chip.word(0x15)
        chip.settings(0, voltage=pack_voltage)
        if not full_idle(pack()):
            raise StopCharge("pack left full standby during input recovery")
        present, enabled = chip.input_present(), sink.switches()
        log("full-input-before", ac=present, consumer=enabled, voltage_mV=voltage,
            charge_voltage_mV=pack_voltage)
        if present and not enabled:
            raise StopCharge("BQ already supplied through a different path")
        if voltage != 12000 and not (present and enabled):
            return False  # use the verified 12 V contract before opening input
        if stopping.is_set():
            return False
        if not enabled:
            chip.limit_input(voltage=pack_voltage)
            sink.check(known, 12000)
            # Recheck after negotiation and input-limit writes, before opening.
            chip.settings(0, voltage=pack_voltage)
            if not full_idle(pack()):
                raise StopCharge("pack left full standby before input enable")
            if stopping.is_set():
                return False
            self.owned, self.known = True, known
            sink.consumer(True)
        wait_for("BQ standby adapter present", chip.input_present, 4)
        chip.limit_input(voltage=pack_voltage)
        log("full-input-ready", ac=True, consumer=1, charge_target_mA=0,
            charge_voltage_mV=pack_voltage, switch_owned=self.owned)
        return True

    def detached(self):
        self.owned = False

    def close(self):
        if self.owned:
            pd = poll_port()
            if pd.get("attached") and pd.get("pd_state") != 0 and not pd.get("source"):
                self.sink.consumer(False)
                log("full-consumer-off")


def recover_startup(events, sink, chip):
    standby = FullInput(sink, chip)
    try:
        _recover_startup(events, sink, chip, standby)
    finally:
        standby.close()


def _recover_startup(events, sink, chip, standby):
    """Inspect boot once, then use GPIO101 to start bounded connection windows.

    A NACK at boot is not proof of detachment and authorizes no write. It leaves
    the process waiting for an actual edge. The first live contract establishes
    the fixed 12 V / 3 A PDO used for all subsequent connections in this process.
    """
    known = None
    initial = armed = True
    requested = False
    deadline = None
    while not stopping.is_set():
        if initial:
            initial = False
            pd = poll_port()
            check_role(pd)
            if not pd or is_detached(pd):
                log("startup-idle", observed="detached" if pd else "unconfirmed")
                continue
            if pd.get("stable_state") and not pd.get("attached"):
                raise StopCharge("unrecognized initial IC10 state")
            deadline = uptime() + 10
        else:
            if deadline is None:
                log("idle-wait", after_seq=events.seq,
                    waiting_for="attach" if armed else "detach")
            event = events.next(None if deadline is None else max(0, deadline - uptime()))
            if stopping.is_set():
                return
            if event and event.detached:
                battery = wait_for("battery discharge after GPIO101 detach", discharging_pack, 3, delay=0.1)
                standby.detached()
                if chip.word(0x14) in FIRMWARE_CHARGE.values() and not chip.input_present():
                    chip.set_current(0)
                log("detached", seq=event.seq, **battery)
                armed, requested, deadline = True, False, None
                continue
            if event and event.state & 0xe2000000:
                raise StopCharge("IC10 role, short or reset changed")
            if not armed:
                continue
            if deadline is None:
                if event is None or not event.state & (1 << 24):
                    continue
                deadline = uptime() + 10
            pd = poll_port()
            check_role(pd)

        if is_detached(pd):
            # A transition may settle without a further edge. Reading a stable
            # detach at the deadline authorizes only waiting for a new attach.
            log("disconnected-idle", pd=pd)
            standby.detached()
            armed, requested, deadline = True, False, None
            continue
        expired = uptime() >= deadline
        voltage = pd.get("requested_mV")
        if voltage:
            candidate = profile(pd)
            if (known is not None and candidate != known
                    or pd.get("requested_mA") != 3000 or voltage not in (5000, 12000)):
                raise StopCharge("source or negotiated current changed")
            # Includes the Samsung dry/attached checks and a second live read.
            sink.check(candidate, voltage)
            known = candidate
            battery = pack()
            chip.identify()
            current = chip.word(0x14)
            charge_voltage = chip.word(0x15)
            full = full_idle(battery)
            if full:
                if current != 0:
                    raise StopCharge("full pack has a nonzero charge target")
                if standby.ready(known, voltage):
                    log("full-idle", pd=pd, charge_voltage_mV=chip.word(0x15), **battery)
                    armed, requested, deadline = False, False, None
                    if wait_full(events, sink, chip, known, input_voltage=voltage,
                                 charge_voltage=charge_voltage):
                        initial, armed = True, True
                    continue
                if stopping.is_set():
                    return

            if current and current != FIRMWARE_CHARGE.get(charge_voltage):
                raise StopCharge("unknown initial charge target")
            if current and not chip.input_present() and battery["current_now"] < 0:
                # Firmware can program a target even while no adapter supplies
                # the BQ. Clear that known, inactive preset before negotiation.
                chip.settings(current, voltage=charge_voltage)
                chip.set_current(0)
                log("inactive-firmware-target-cleared", previous_mA=current,
                    charge_voltage_mV=charge_voltage)
                current = 0
            if not full:
                pack_target(battery, starting=current == 0)
            if voltage == 12000:
                if stopping.wait(0.5):
                    return
                sink.check(known, 12000)
                if current == 0:
                    charge_voltage = initialize_voltage(sink, chip, known)
                if stopping.is_set():
                    return
                log("charge-ready", seq=events.seq, previous_mA=current, pd=pd)
                charge_after_replug(sink, chip, known, wait=events.wait_charging,
                                    initial_current=current, voltage=charge_voltage,
                                    on_full=lambda: wait_full(events, sink, chip, known,
                                        input_voltage=12000, charge_voltage=charge_voltage))
                armed, requested, deadline = False, False, None
                continue
            if current:
                raise StopCharge("unexpected active charge on the 5 V contract")
            # Zero-current reset state may negotiate first. Its voltage ceiling
            # can only be initialized after a live 12 V contract and pack check.
            if not full:
                chip.settings(0, voltage=chip.word(0x15))
            if not requested and not expired:
                if stopping.is_set():
                    return
                sink.select(known)
                log("requested-12V", seq=events.seq, pdo=known[0])
                requested = True
        if expired:
            raise StopCharge("timed out negotiating 12 V during startup or attach")

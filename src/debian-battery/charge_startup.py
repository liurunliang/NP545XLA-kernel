#!/usr/bin/python3
"""Opt-in IC10 startup policy for the original 12 V / 3 A source."""
from hotplug import (FIRMWARE_MA, StopCharge, charge_after_replug, is_detached, log,
                     pack, pack_target, poll_port, profile, stopping, uptime, wait_for)


def full_idle(battery):
    # 0x40e0 is the measured full pack: initialized, full, discharging and
    # terminate-charge. Other alarms/errors must not become a normal idle state.
    flags = battery["flags"]
    return (flags & 0xa0 == 0xa0 and not flags & 0x9b0f
            and battery["constant_charge_current_max"] == 0)


def discharging_pack():
    battery = pack()
    return battery if battery["current_now"] < 0 else None


def check_role(pd):
    if pd and (int(pd["state_hex"], 16) & 0xe2000000 or pd.get("source")):
        raise StopCharge("IC10 role, short or reset changed")


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
                if chip.word(0x14) == FIRMWARE_MA and not chip.input_present():
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
            full = full_idle(battery)
            if full:
                if current != 0:
                    raise StopCharge("full pack has a nonzero charge target")
                if standby.ready(known, voltage):
                    log("full-idle", pd=pd, charge_voltage_mV=chip.word(0x15), **battery)
                    armed, requested, deadline = False, False, None
                    continue
                if stopping.is_set():
                    return

            if not full:
                pack_target(battery, starting=current == 0)
            if current not in (0, FIRMWARE_MA):
                raise StopCharge("unknown initial charge target")
            if voltage == 12000:
                if stopping.wait(0.5):
                    return
                sink.check(known, 12000)
                log("charge-ready", seq=events.seq, previous_mA=current, pd=pd)
                charge_after_replug(sink, chip, known, wait=events.wait_charging,
                                    initial_current=current)
                armed, requested, deadline = False, False, None
                continue
            if current:
                raise StopCharge("unexpected active charge on the 5 V contract")
            # Validate BQ and pack limits before asking the PD controller to
            # renegotiate. The existing 8760 mV gate is intentionally retained.
            if not full:
                chip.settings(0)
            if not requested and not expired:
                if stopping.is_set():
                    return
                sink.select(known)
                log("requested-12V", seq=events.seq, pdo=known[0])
                requested = True
        if expired:
            raise StopCharge("timed out negotiating 12 V during startup or attach")

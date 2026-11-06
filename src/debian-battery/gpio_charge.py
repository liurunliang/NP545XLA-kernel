#!/usr/bin/python3
"""Drive IC10 hotplug recovery from GPIO101; sleep indefinitely while idle."""
from collections import deque
from contextlib import ExitStack
from dataclasses import dataclass
import os
from pathlib import Path
import select
import signal
import sys
import time

import ic10_irq as trace
from hotplug import (FIRMWARE_MA, InputCharger, Sink, StopCharge, boot_profile, charge_after_replug,
                     check_boot_input, log, pack, poll_port, profile, stopping, uptime, wait_for)
from irq_ack import AckPort, PIN, acknowledge, claim_gpio
from np545_charge_observe import DT


@dataclass(frozen=True)
class PortEvent:
    seq: int
    state: int
    detached: bool


class Interrupts:
    def __init__(self, line, chip, wake_fd):
        self.line = line
        self.chip = chip
        self.wake_fd = wake_fd
        self.seq = 0
        self.recent = deque(maxlen=64)
        self.pending = None

    def snapshot(self):
        result = acknowledge(self.chip, self.line, self.seq, publish_detach=False)
        if stopping.is_set():
            return None
        if result is None:
            raise StopCharge("IRQ status or return to high could not be verified")
        return PortEvent(self.seq, *result)

    def next(self, timeout):
        if self.pending is not None:
            event, self.pending = self.pending, None
            return event
        if stopping.is_set():
            return None
        ready, _, _ = select.select([self.line.fd, self.wake_fd], [], [], timeout)
        if self.wake_fd in ready or stopping.is_set():
            return None
        if not ready:
            return None
        edge = self.line.read_edge_events(max_events=1)[0]
        if edge.line_offset != PIN or edge.line_seqno != self.seq + 1:
            raise StopCharge("lost GPIO101 interrupt sequence")
        self.seq = edge.line_seqno
        self.recent.append(edge.timestamp_ns)
        if len(self.recent) == self.recent.maxlen and self.recent[-1] - self.recent[0] < 1_000_000_000:
            raise StopCharge("GPIO101 interrupt storm")
        offset = trace.boottime() - time.monotonic_ns()
        trace.log("edge", seq=self.seq, edge_boot_ns=edge.timestamp_ns + offset)
        return self.snapshot()

    def wait_charging(self, seconds):
        event = self.next(seconds)
        if event and (event.detached or not event.state & (1 << 24) or event.state & (1 << 25)):
            self.pending = event  # deliver it to the idle policy after current is set to zero
            return True
        return stopping.is_set()


def discharging_pack():
    battery = pack()
    return battery if battery["current_now"] < 0 else None


def recover(events, sink, chip, known):
    armed = requested = False
    deadline = None
    while not stopping.is_set():
        if deadline is None:
            log("idle-wait", after_seq=events.seq, waiting_for="attach" if armed else "detach")
        event = events.next(None if deadline is None else max(0, deadline - uptime()))
        if stopping.is_set():
            return
        if event and event.detached:
            battery = wait_for("battery discharge after GPIO101 detach", discharging_pack, 3, delay=0.1)
            if chip.word(0x14) == FIRMWARE_MA and not chip.input_present():
                chip.set_current(0)
            log("detached", seq=event.seq, **battery)
            armed, requested, deadline = True, False, None
            continue
        if not armed or (event and (not event.state & (1 << 24) or event.state & (1 << 25))):
            continue
        # Only an attach IRQ starts the bounded negotiation window. A single
        # deadline read covers coalesced readiness indications during negotiation.
        if deadline is None:
            if event is None:
                continue
            deadline = uptime() + 10
        expired = uptime() >= deadline
        pd = poll_port()
        voltage = pd.get("requested_mV")
        if voltage:
            if profile(pd) != known or pd.get("requested_mA") != 3000 or voltage not in (5000, 12000):
                raise StopCharge("source or negotiated current changed")
            if not requested:
                log("reattached", seq=events.seq, pd=pd)
            if voltage == 12000:
                if stopping.wait(0.5):
                    return
                pd = sink.check(known, 12000)
                log("contract-12V", seq=events.seq, pd=pd)
                charge_after_replug(sink, chip, known, wait=events.wait_charging)
                armed, requested, deadline = False, False, None
                continue
            if not requested and not expired:
                sink.select(known)
                log("requested-12V", seq=events.seq, pdo=known[0])
                requested = True
        if expired:
            raise StopCharge("timed out negotiating 12 V after attach interrupt")


def stop(*unused):
    trace.stopped = True
    stopping.set()


def run():
    args = set(Path("/proc/cmdline").read_text().split())
    if (not {"np545.gpiocharge=1", "np545.battery=1"} <= args
            or args & {"np545.hotplug=1", "np545.irqack=1", "np545.ic10irq=1", "np545.keepcharge=1"}
            or b"samsung,np545xla" not in (DT / "compatible").read_bytes().split(b"\0")):
        raise StopCharge("select the dedicated GPIO101 hotplug entry")
    with ExitStack() as stack:
        # SIGTERM must wake the same blocking wait as a GPIO edge, including
        # in the gap between testing the stop flag and entering select().
        rd, wr = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
        stack.callback(os.close, rd)
        stack.callback(os.close, wr)
        old_fd = signal.set_wakeup_fd(wr)
        stack.callback(signal.set_wakeup_fd, old_fd)
        for sig in (signal.SIGTERM, signal.SIGINT):
            previous = signal.signal(sig, stop)
            stack.callback(signal.signal, sig, previous)
        line = claim_gpio(stack, "np545-gpiocharge")
        known = boot_profile()
        sink = stack.enter_context(Sink())
        chip = stack.enter_context(InputCharger())
        pd_irq = stack.enter_context(AckPort())
        check_boot_input(sink, chip, known)
        events = Interrupts(line, pd_irq, rd)
        initial = line.get_value(PIN).value
        trace.log("armed", boot_id=Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                  level=initial, irqs=trace.counts())
        if not initial and not line.wait_edge_events(timeout=0):
            events.pending = events.snapshot()
        try:
            recover(events, sink, chip, known)
        finally:
            trace.log("closing", seq=events.seq, level=line.get_value(PIN).value, irqs=trace.counts())
    trace.log("released", line=trace.lines()[PIN], irqs=trace.counts())


if __name__ == "__main__":
    try:
        run()
    except (StopCharge, RuntimeError, OSError, ValueError) as exc:
        log("exit", reason=str(exc))
        sys.exit(0 if stopping.is_set() else 1)

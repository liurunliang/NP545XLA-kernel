#!/usr/bin/python3
"""Acknowledge a pending IC10 S2MM005 IRQ and measure GPIO101 rearming."""
from collections import deque
from contextlib import ExitStack
import errno
import os
from pathlib import Path
import signal
import time

import gpiod
from gpiod.line import Bias, Clock, Direction, Edge

import ic10_irq as trace
from hotplug import pd_mailbox, send
from np545_charge_observe import DT, Registers

PIN = 101


class AckPort(Registers):
    open_flags = os.O_RDWR
    pd_regs = {**Registers.pd_regs, 0x08: 1, 0x30: 48, 0x60: 4}

    def __init__(self):
        super().__init__("ic10", 0x33)


def acknowledge(chip, line, seq):
    level = lambda: line.get_value(PIN).value
    # Exclude select-PDO, state-machine and consumer-switch transactions until
    # the status snapshot and its acknowledgment are complete.
    with pd_mailbox(chip):
        if level():
            trace.log("already-high", seq=seq)
            return
        for attempt in range(3):
            try:
                state = chip.word(0x20)
                lp = chip.word(0x60)
                status = chip.read(0x30)
                break
            except OSError as exc:
                if attempt == 2 or exc.errno not in (errno.ENXIO, errno.EREMOTEIO):
                    raise
                time.sleep(0.005)
        if state & 0xe0000000 or lp & 0x48 or status == b"\xff" * 48:
            raise RuntimeError(f"unsafe or invalid PD snapshot: state={state:#x}, LP={lp:#x}")
        # NP545XLA EmuEC 0xd5c0 calls its wake routine before the clear.
        for _ in range(5):
            chip.read(0x08)
        time.sleep(0.00001)
        if level() or trace.stopped:
            trace.log("clear-skipped", seq=seq, state=state, status_hex=status.hex())
            return
        start = trace.boottime()
        send(chip, bytes.fromhex("00 10 01"))
        written = trace.boottime()
        until = time.monotonic() + 0.03
        high = level()
        while not high and time.monotonic() < until:
            time.sleep(0.0003)
            high = level()
        trace.log("ack", seq=seq, state=state, status_hex=status.hex(), before=0,
                  write_start_ns=start, write_done_ns=written, after=high)
        if not high:
            # A new assertion and a stuck-low line cannot be distinguished here.
            # Do not emit another ACK on the same low level.
            trace.log("release-unconfirmed", seq=seq)


def run():
    args = set(Path("/proc/cmdline").read_text().split())
    if (not {"np545.irqack=1", "np545.hotplug=1", "np545.battery=1"} <= args
            or "np545.ic10irq=1" in args or "np545.keepcharge=1" in args
            or b"samsung,np545xla" not in (DT / "compatible").read_bytes().split(b"\0")):
        raise SystemExit("select the independent IC10 IRQ acknowledgment trial")
    with ExitStack() as stack:
        for path in sorted(Path("/dev").glob("gpiochip*")):
            gpio = stack.enter_context(gpiod.Chip(str(path)))
            if gpio.get_info().label == trace.LABEL:
                break
        else:
            raise RuntimeError("Samsung TLMM not found")
        state, owner = trace.lines()[PIN]
        info = gpio.get_line_info(PIN)
        if (not state.startswith("in ") or "func0" not in state.split() or owner != "UNCLAIMED"
                or info.used or info.direction != Direction.INPUT):
            raise RuntimeError(f"GPIO101 unavailable: {state} / {owner}")
        cfg = gpiod.LineSettings(direction=Direction.INPUT, bias=Bias.AS_IS,
                                 edge_detection=Edge.FALLING, event_clock=Clock.MONOTONIC)
        line = stack.enter_context(gpio.request_lines({PIN: cfg}, consumer="np545-irq-ack",
                                                      event_buffer_size=128))
        chip = stack.enter_context(AckPort())
        recent = deque(maxlen=64)
        seq = 0
        initial = line.get_value(PIN).value
        trace.log("armed", boot_id=Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                  pin=PIN, initial=initial, irqs=trace.counts())
        if not initial and not line.wait_edge_events(timeout=0):
            acknowledge(chip, line, seq)
        while not trace.stopped:
            if not line.wait_edge_events(timeout=0.5):
                continue
            for edge in line.read_edge_events():
                if trace.stopped:
                    break
                if edge.line_seqno != seq + 1 or edge.line_offset != PIN:
                    raise RuntimeError("unexpected GPIO edge or lost sequence")
                seq = edge.line_seqno
                recent.append(edge.timestamp_ns)
                if len(recent) == 64 and recent[-1] - recent[0] < 1_000_000_000:
                    raise RuntimeError("IRQ storm; stop acknowledging")
                offset = trace.boottime() - time.monotonic_ns()
                trace.log("edge", seq=seq, pin=PIN, edge_boot_ns=edge.timestamp_ns + offset)
                acknowledge(chip, line, seq)
        trace.log("closing", seq=seq, level=line.get_value(PIN).value, irqs=trace.counts())
    trace.log("released", pin=PIN, line=trace.lines()[PIN], irqs=trace.counts())


if __name__ == "__main__":
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, trace.stop)
    try:
        run()
    except (OSError, RuntimeError) as exc:
        trace.log("exit", reason=str(exc))
        raise SystemExit(1)

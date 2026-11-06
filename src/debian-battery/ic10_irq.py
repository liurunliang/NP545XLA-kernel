#!/usr/bin/python3
"""Timestamp input edges independently of the existing IC10 hotplug policy."""
from contextlib import ExitStack
import json
from pathlib import Path
import re
import selectors
import signal
import time

import gpiod
from gpiod.line import Bias, Clock, Direction, Edge

from np545_charge_observe import DT, port

# EMEC _CRS GpioInt order; virtual 704 -> GPIO101, 768 -> GPIO119.
PINS = (101, 26, 41, 119, 81, 42)
LABEL = "3100000.pinctrl"
DEBUG = Path("/sys/kernel/debug")
GPIO = DEBUG / "gpio"
MUX = DEBUG / "pinctrl" / LABEL / "pinmux-pins"
stopped = False


def boottime():
    return time.clock_gettime_ns(time.CLOCK_BOOTTIME)


def log(event, **fields):
    print(json.dumps(dict(event=event, boottime_ns=boottime(), **fields)), flush=True)


def lines():
    gpio = GPIO.read_text().split("parent: platform/3100000.pinctrl, 3100000.pinctrl:\n", 1)[1]
    gpio = gpio.split("gpiochip", 1)[0]
    mux = MUX.read_text()
    result = {}
    for pin in PINS:
        state = re.search(rf"^\s*gpio{pin}\s*:\s*(.+)$", gpio, re.M)
        owner = re.search(rf"^pin {pin} \(GPIO_{pin}\): (.+)$", mux, re.M)
        if not state or not owner:
            raise RuntimeError(f"no TLMM description for GPIO{pin}")
        result[pin] = (state[1].strip(), owner[1].strip())
    return result


def counts():
    rows = {}
    for line in Path("/proc/interrupts").read_text().splitlines():
        match = re.search(r"^\s*(\d+):\s*([\d\s]+)\bmsmgpio\s+(\d+)\s+(\S+)\s+(.+)$", line)
        if match and int(match[3]) in PINS:
            rows[int(match[3])] = dict(irq=int(match[1]), count=sum(map(int, match[2].split())),
                                       trigger=match[4], name=match[5])
    return rows


def pd_state():
    try:
        pd = port("ic10")
        return {key: pd.get(key) for key in ("state_hex", "stable_state", "attached",
                                            "selected_pdo", "requested_mV", "requested_mA")}
    except OSError as exc:
        return {"errno": exc.errno}


def stop(*unused):
    global stopped
    stopped = True


def run():
    args = set(Path("/proc/cmdline").read_text().split())
    if (not {"np545.ic10irq=1", "np545.hotplug=1", "np545.battery=1"} <= args
            or b"samsung,np545xla" not in (DT / "compatible").read_bytes().split(b"\0")):
        raise SystemExit("select the IC10 IRQ trace trial")
    with ExitStack() as stack:
        chip = None
        for path in sorted(Path("/dev").glob("gpiochip*")):
            candidate = stack.enter_context(gpiod.Chip(str(path)))
            if candidate.get_info().label == LABEL:
                chip = candidate
                break
        if chip is None:
            raise RuntimeError("Samsung TLMM not found")
        selector = stack.enter_context(selectors.DefaultSelector())
        requests = {}
        initial = lines()
        settings = gpiod.LineSettings(direction=Direction.INPUT, bias=Bias.AS_IS,
                                      edge_detection=Edge.FALLING, event_clock=Clock.MONOTONIC)
        log("baseline", boot_id=Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
            lines=initial, irqs=counts())
        for pin, (state, owner) in initial.items():
            info = chip.get_line_info(pin)
            if (not re.match(r"in\s+(high|low)\s+func0\b", state) or owner != "UNCLAIMED"
                    or info.used or info.direction != Direction.INPUT):
                log("passive-only", pin=pin, state=state, owner=owner)
                continue
            try:
                req = stack.enter_context(chip.request_lines({pin: settings}, consumer="np545-ic10-irq",
                                                             event_buffer_size=128))
            except OSError as exc:
                log("unavailable", pin=pin, errno=exc.errno)
                continue
            selector.register(req.fd, selectors.EVENT_READ, req)
            requests[pin] = req
        if not requests:
            raise RuntimeError("no free candidate input")
        log("armed", pins=list(requests), irqs=counts())
        last = None
        heartbeat = due = 0
        while not stopped:
            items = selector.select(max(0, due - time.monotonic()))
            for key, _ in items:
                for edge in key.data.read_edge_events():
                    offset = boottime() - time.monotonic_ns()
                    log("edge", pin=edge.line_offset, kind=edge.event_type.name,
                        seq=edge.line_seqno, edge_mono_ns=edge.timestamp_ns,
                        edge_boot_ns=edge.timestamp_ns + offset)
            now = time.monotonic()
            if not items and now < due:
                continue
            start = boottime()
            levels = {pin: req.get_value(pin).value for pin, req in requests.items()}
            pd = pd_state()
            snapshot = (levels, pd)
            if snapshot != last or items or now >= heartbeat:
                log("sample", start_ns=start, levels=levels, pd=pd, irqs=counts())
                last = snapshot
                heartbeat = now + 3
            due = now + 0.12
        log("closing", irqs=counts())
    log("released", lines=lines(), irqs=counts())


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    run()

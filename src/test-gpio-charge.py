#!/usr/bin/env python3
"""Check idle blocking, confirmed transitions and IRQ handoff in the USB trial."""
import unittest
from contextlib import ExitStack
from unittest.mock import Mock, patch

import gpio_charge as gc


class InterruptTests(unittest.TestCase):
    def test_idle_select_has_no_timer_and_termination_needs_no_gpio_access(self):
        line = Mock(fd=23)
        irq = gc.Interrupts(line, Mock(), 24)
        with patch.object(gc.select, "select", return_value=([24], [], [])) as wait:
            self.assertIsNone(irq.next(None))
        wait.assert_called_once_with([23, 24], [], [], None)
        line.read_edge_events.assert_not_called()

    def test_detach_interrupt_interrupts_active_wait_and_is_delivered_once(self):
        line = Mock(fd=23)
        line.read_edge_events.return_value = [Mock(line_offset=101, line_seqno=1, timestamp_ns=100)]
        irq = gc.Interrupts(line, Mock(), 24)
        with patch.object(gc.select, "select", return_value=([23], [], [])) as wait, patch.object(
                gc.trace, "log"), patch.object(gc, "acknowledge", return_value=(0x08ff1100, True)):
            self.assertTrue(irq.wait_charging(1))
            event = irq.next(None)
            self.assertEqual(event, gc.PortEvent(1, 0x08ff1100, True))
            wait.assert_called_once_with([23, 24], [], [], 1)
            self.assertIsNone(irq.pending)

    def test_idle_attach_alone_cannot_arm_and_two_cycles_renegotiate(self):
        # (seq, raw, verified detach). A duplicate attach without a new detach
        # must leave the second charge unarmed.
        kinds = [(0x19ff2415, False), (0x08ff1100, True), (0x19ff2411, False),
                 (0x19ff2415, False), (0x19ff2415, False), (0x19ff2415, False),
                 (0x08ff1100, True), (0x19ff2415, False)]
        events, sink, chip = Mock(), Mock(), Mock()
        waits = []
        seq = 0
        stop = gc.stopping.__class__()
        def get(timeout):
            nonlocal seq
            waits.append(timeout)
            if seq == len(kinds):
                stop.set()
                return None
            seq += 1
            events.seq = seq
            return gc.PortEvent(seq, *kinds[seq-1])
        events.next.side_effect = get
        pd5 = dict(requested_mV=5000, requested_mA=3000)
        pd12 = dict(requested_mV=12000, requested_mA=3000)
        with ExitStack() as stack:
            for name, value in dict(stopping=stop, poll_port=Mock(side_effect=[{}, pd5, pd12, pd12]),
                                    log=Mock(), discharging_pack=lambda: {"current_now": -900000},
                                    profile=lambda _: (3, 123), charge_after_replug=Mock()).items():
                stack.enter_context(patch.object(gc, name, value))
            stack.enter_context(patch.object(stop, "wait", return_value=False))
            gc.recover(events, sink, chip, (3, 123))
            self.assertEqual(gc.poll_port.call_count, 4)
            self.assertEqual(gc.charge_after_replug.call_count, 2)
            sink.select.assert_called_once_with((3,123))
            self.assertEqual([i for i,t in enumerate(waits) if t is not None], [3,4])


if __name__ == "__main__":
    unittest.main()

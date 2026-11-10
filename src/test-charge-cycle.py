#!/usr/bin/env python3
"""Exercise full/recharge transitions with the real policy and no hardware I/O."""
import importlib.util
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import Mock, patch

src = Path(__file__).resolve().parent
for name, path in (("np545_charge_observe", src / "probe-debian-charge.py"),
                   *((n, src / f"debian-battery/{n}.py")
                     for n in ("keepcharge", "hotplug", "charge_startup"))):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)

import charge_startup as cs
import hotplug as hp


class CycleTests(unittest.TestCase):
    pd = dict(requested_mV=12000, requested_mA=3000, selected_pdo=3,
              stable_state=True, pd_state=21, attached=True, source=False,
              state_hex="19ff2415",
              caps_hex="615100002c91010a2cd102002cc103002cb104002c4106000000000000000000")
    full = dict(flags=0x40a0, temp=295, capacity=98, voltage_now=8670000,
                constant_charge_voltage_max=0, constant_charge_current_max=0, current_now=0)
    hungry = dict(flags=0xc0, temp=295, capacity=95, voltage_now=8450000,
                  constant_charge_voltage_max=8860000, constant_charge_current_max=4256000,
                  current_now=0)

    def setUp(self):
        self.pd = dict(type(self).pd)
        self.now = 20
        self.end = 84
        self.stop = threading.Event()
        self.enabled = False
        self.writes, self.switches, self.reads = [], [], []
        self.regs = {0xfe: 0x40, 0xff: 0x89, 0x12: 0xe70e, 0x15: 8696,
                     0x22: 0x3c00, 0x3f: 0x3c00, 0x14: 0, 0x20: 0}
        self.chip = hp.InputCharger.__new__(hp.InputCharger)
        self.chip.word = self.regs.__getitem__
        self.chip.set_current = self.write
        self.sink = Mock()
        self.sink.switches.side_effect = lambda: int(self.enabled)
        self.sink.consumer.side_effect = self.consumer
        self.sink.check.return_value = self.pd
        self.events = Mock(seq=0)
        self.events.wait_charging.side_effect = self.advance
        self.events.next.side_effect = AssertionError("Unexpected idle wait")
        self.timeline = lambda t: self.full if 22 <= t < 52 else self.hungry
        self.after_wait = lambda: None
        for module in (cs, hp):
            for name, value in dict(stopping=self.stop, uptime=lambda: self.now,
                                    pack=self.pack, log=Mock(), poll_port=lambda: self.pd).items():
                self.enterContext(patch.object(module, name, value))
        self.enterContext(patch.object(self.stop, "wait", self.advance))

    def write(self, ma):
        self.assertTrue(0 <= ma <= 1024 and ma % 64 == 0)
        self.writes.append((self.now, ma))
        self.regs[0x14] = ma

    def consumer(self, on):
        self.switches.append((self.now, on))
        self.enabled = on
        self.regs[0x20] = 0x8000 if on else 0

    def advance(self, seconds):
        self.now += min(seconds, max(0, self.end - self.now))
        self.after_wait()
        if self.now >= self.end:
            self.stop.set()
        return self.stop.is_set()

    def pack(self):
        self.reads.append(self.now)
        battery = dict(self.timeline(self.now))
        if not battery['flags'] & 0x20 and self.regs[0x14]:
            battery.update(flags=0x80, current_now=900000)
        return battery

    def wait_full(self):
        return cs.wait_full(self.events, self.sink, self.chip, hp.profile(self.pd),
                            input_voltage=12000, charge_voltage=8696)

    def run_cycle(self, **kwargs):
        hp.charge_after_replug(self.sink, self.chip, hp.profile(self.pd),
                              wait=self.events.wait_charging, voltage=8696,
                              on_full=self.wait_full, **kwargs)

    def test_charge_full_wait_recharge_keeps_input_and_lower_voltage(self):
        self.run_cycle()
        self.assertEqual(self.writes, [(20, 1024), (22, 0), (82, 1024), (84, 0)])
        self.assertEqual(self.switches, [(20, True), (84, False)])
        self.assertEqual(self.regs[0x15], 8696)
        # Full waiting samples at 22, 52, 82, without one-second battery polling.
        self.assertFalse(any(22 < t < 52 or 52 < t < 82 for t in self.reads))

    def test_soc_hysteresis_requires_two_consecutive_eligible_samples(self):
        self.end = 174
        def timeline(t):
            if 22 <= t < 52:
                return self.full
            return dict(self.hungry, capacity=96 if 52 <= t < 82 or 112 <= t < 142 else 95)
        self.timeline = timeline
        self.run_cycle()
        self.assertEqual([t for t, ma in self.writes if ma], [20, 172])

    def test_full_flag_blocks_restart_even_below_threshold(self):
        self.end = 114
        self.timeline = lambda t: dict(self.full, capacity=94) if 22 <= t < 82 else self.hungry
        self.run_cycle()
        self.assertEqual([t for t, ma in self.writes if ma], [20, 112])

    def test_zero_request_waits_without_becoming_a_fault(self):
        self.end = 114
        self.timeline = lambda t: (self.full if 22 <= t < 52 else
            dict(self.hungry, constant_charge_current_max=0) if 52 <= t < 82 else self.hungry)
        self.run_cycle()
        self.assertEqual([t for t, ma in self.writes if ma], [20, 112])

    def test_alarm_temperature_invalid_voltage_or_capacity_cannot_restart(self):
        changes = [dict(flags=0x50a0), dict(flags=0x4080), dict(flags=0x81),
                   dict(temp=401), dict(temp=0xffff), dict(capacity=101),
                   dict(voltage_now=8900000), dict(constant_charge_voltage_max=65535000),
                   dict(constant_charge_current_max=65535000)]
        for change in changes:
            with self.subTest(change=change):
                # Each scenario needs an independent input/ownership lifecycle.
                self.now = 20
                self.stop.clear()
                self.writes.clear()
                self.switches.clear()
                self.timeline = lambda t: (self.full if 22 <= t < 52 else
                    dict(self.full, **change) if t >= 52 else self.hungry)
                with self.assertRaises(hp.StopCharge):
                    self.run_cycle()
                self.assertEqual([ma for _, ma in self.writes if ma], [1024])
                self.assertEqual(self.regs[0x14], 0)
                self.assertFalse(self.enabled)

    def test_read_failure_stops_without_restart(self):
        def timeline(t):
            if t >= 52:
                raise OSError("SBS unavailable")
            return self.full if t >= 22 else self.hungry
        self.timeline = timeline
        with self.assertRaisesRegex(OSError, "SBS unavailable"):
            self.run_cycle()
        self.assertEqual([ma for _, ma in self.writes if ma], [1024])
        self.assertEqual(self.regs[0x14], 0)

    def test_stop_interrupts_full_wait_and_closes_owned_input(self):
        self.end = 25
        self.run_cycle()
        self.assertEqual(self.now, 25)
        self.assertEqual([ma for _, ma in self.writes], [1024, 0, 0])
        self.assertEqual(self.switches, [(20, True), (25, False)])

    def test_detach_interrupt_returns_without_waiting_for_next_sample(self):
        def wait(seconds):
            if self.now == 22:
                self.now = 25
                self.regs[0x20] = 0
                return True  # Interrupts retains the detach for the outer policy.
            return self.advance(seconds)
        self.events.wait_charging.side_effect = wait
        self.run_cycle()
        self.assertEqual(self.now, 25)
        self.assertEqual([ma for _, ma in self.writes if ma], [1024])

    def test_changed_hardware_settings_prevent_recharge(self):
        self.after_wait = lambda: self.regs.update({0x15: 8760}) if self.now >= 52 else None
        with self.assertRaisesRegex(hp.StopCharge, "charge target changed"):
            self.run_cycle()
        self.assertEqual([ma for _, ma in self.writes if ma], [1024])

    def test_full_at_session_entry_never_writes_nonzero_until_recharge(self):
        self.end = 82
        self.timeline = lambda t: self.full if t < 50 else self.hungry
        self.run_cycle()
        self.assertEqual([t for t, ma in self.writes if ma], [80])
        self.assertEqual(self.switches, [(20, True), (82, False)])

    def test_full_boot_restarts_without_a_port_edge(self):
        self.end = 83
        self.timeline = lambda t: self.full if t < 50 else self.hungry
        cs.recover_startup(self.events, self.sink, self.chip)
        self.assertEqual([t for t, ma in self.writes if ma], [80.5])
        self.events.next.assert_not_called()
        self.assertEqual(self.regs[0x15], 8696)
        self.assertEqual(self.switches, [(20, True), (83, False)])

    def test_full_boot_with_nonzero_pack_request_stays_at_zero(self):
        self.timeline = lambda t: dict(self.full, constant_charge_current_max=5320000,
                                       constant_charge_voltage_max=8860000)
        cs.recover_startup(self.events, self.sink, self.chip)
        self.assertEqual(self.writes, [])
        self.assertEqual(self.regs[0x14], 0)
        self.assertEqual(self.switches, [(20, True), (84, False)])

    def test_full_5v_input_is_renegotiated_before_recharge(self):
        self.enabled = True
        self.regs[0x20] = 0x8000
        self.pd.update(requested_mV=5000, selected_pdo=1)
        self.end = 83
        self.timeline = lambda t: self.full if t < 50 else self.hungry
        self.sink.select.side_effect = lambda known: self.pd.update(requested_mV=12000, selected_pdo=3)
        self.events.next.side_effect = lambda timeout: Mock(state=0x19ff2415, detached=False)
        original_write = self.chip.set_current
        def write(ma):
            if ma:
                self.assertEqual(self.pd['requested_mV'], 12000)
            original_write(ma)
        self.chip.set_current = write
        cs.recover_startup(self.events, self.sink, self.chip)
        self.sink.select.assert_called_once()
        self.assertEqual([t for t, ma in self.writes if ma], [80.5])
        self.assertEqual(self.switches, [])  # inherited input is not ours to close

    def test_failed_zero_readback_never_enters_recharge(self):
        original_write = self.chip.set_current
        def write(ma):
            original_write(ma)
            if ma == 0:
                raise OSError("zero readback unavailable")
        self.chip.set_current = write
        with self.assertRaisesRegex(OSError, "zero readback unavailable"):
            self.run_cycle()
        self.assertEqual([ma for _, ma in self.writes if ma], [1024])
        self.assertFalse(self.enabled)

    def test_long_sampling_gap_restarts_the_confirmation_count(self):
        self.end = 234
        skipped = False
        def wait(seconds):
            nonlocal skipped
            if self.now == 52 and not skipped:
                skipped = True
                self.now = 202
                return False
            return self.advance(seconds)
        self.events.wait_charging.side_effect = wait
        self.run_cycle()
        self.assertEqual([t for t, ma in self.writes if ma], [20, 232])

    def test_legacy_entry_still_stops_on_full(self):
        with self.assertRaises(hp.FullCharge):
            hp.charge_after_replug(self.sink, self.chip, hp.profile(self.pd),
                                  wait=self.events.wait_charging, voltage=8696)
        self.assertEqual([ma for _, ma in self.writes], [1024, 0])


if __name__ == '__main__':
    unittest.main()

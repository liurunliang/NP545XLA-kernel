#!/usr/bin/env python3
"""Exercise IC10 boot/attach transitions without accessing physical hardware."""
from contextlib import ExitStack
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import ANY, Mock, patch

src = Path(__file__).resolve().parent
for name, path in (("np545_charge_observe", src / "probe-debian-charge.py"),
                   *((name, src / f"debian-battery/{name}.py")
                     for name in ("keepcharge", "hotplug", "charge_startup"))):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)

import charge_startup as cs
import hotplug as hp


class StartupTests(unittest.TestCase):
    five = dict(requested_mV=5000, requested_mA=3000, selected_pdo=1,
                stable_state=True, pd_state=21, attached=True, source=False,
                state_hex="19ff2415",
                caps_hex="615100002c91010a2cd102002cc103002cb104002c4106000000000000000000")
    twelve = dict(five, requested_mV=12000, selected_pdo=3)
    detached = dict(stable_state=True, pd_state=0, attached=False, source=False,
                    state_hex="08ff1100")
    full = dict(flags=0x40e0, temp=317, capacity=98, voltage_now=8638000,
                constant_charge_voltage_max=0, constant_charge_current_max=0,
                current_now=0)
    hungry = dict(flags=0xc0, temp=301, capacity=93, voltage_now=8450000,
                  constant_charge_voltage_max=8860000, constant_charge_current_max=4256000,
                  current_now=-810000)

    def setUp(self):
        self.stop = cs.stopping.__class__()
        self.clock = 20
        self.sink = Mock()
        self.chip = hp.InputCharger.__new__(hp.InputCharger)
        self.regs = {0xfe: 0x40, 0xff: 0x89, 0x12: 0xe70e, 0x15: 8760,
                     0x22: 0x3c00, 0x3f: 0x3c00, 0x14: 0, 0x20: 0x8000}
        self.chip.word = self.regs.__getitem__
        self.chip.set_current = Mock()
        self.events = Mock(seq=0)
        self.events.next.side_effect = self.finish
        self.poll = Mock(return_value=self.twelve)
        self.pack = Mock(return_value=self.hungry)
        self.charge = Mock(side_effect=lambda *a, **kw: self.stop.set())
        for name, value in dict(stopping=self.stop, uptime=lambda: self.clock,
                                log=Mock(), poll_port=self.poll, pack=self.pack,
                                charge_after_replug=self.charge).items():
            self.enterContext(patch.object(cs, name, value))
        self.enterContext(patch.object(self.stop, "wait", return_value=False))
        self.enterContext(patch.object(hp, "uptime", lambda: self.clock))
        self.enterContext(patch.object(hp, "stopping", self.stop))

    def finish(self, timeout):
        self.stop.set()
        return None

    def event(self, detached=False):
        self.events.seq += 1
        return Mock(seq=self.events.seq, state=0x08ff1100 if detached else 0x19ff2415,
                    detached=detached)

    def run_policy(self):
        cs.recover_startup(self.events, self.sink, self.chip)

    def assert_no_power_write(self):
        self.sink.select.assert_not_called()
        self.sink.consumer.assert_not_called()
        self.chip.set_current.assert_not_called()
        self.charge.assert_not_called()

    def test_boot_12v_takes_over_firmware_charge_without_a_detach(self):
        self.regs[0x14] = 3776
        self.pack.return_value = dict(self.hungry, flags=0x80, current_now=900000)
        self.run_policy()
        self.events.next.assert_not_called()
        self.charge.assert_called_once_with(self.sink, self.chip, hp.profile(self.twelve),
                                       wait=self.events.wait_charging, initial_current=3776, voltage=8760, on_full=ANY)

    def test_boot_12v_zero_target_can_start_only_after_all_charge_checks(self):
        self.run_policy()
        self.charge.assert_called_once_with(self.sink, self.chip, hp.profile(self.twelve),
                                       wait=self.events.wait_charging, initial_current=0, voltage=8760, on_full=ANY)

    def test_full_boot_at_5_or_12v_keeps_monitoring_without_changing_8400mv(self):
        for pd in (self.five, self.twelve):
            with self.subTest(voltage=pd["requested_mV"]):
                self.stop.clear()
                self.events.next.reset_mock()
                self.poll.return_value = pd
                self.pack.return_value = self.full
                self.regs[0x15] = 8400
                self.run_policy()
                self.events.next.assert_called_once_with(None)
                self.assertEqual(self.regs[0x15], 8400)
                self.assert_no_power_write()

    def test_detached_or_nack_boot_sleeps_until_an_actual_edge(self):
        for pd in ({}, self.detached):
            with self.subTest(pd=pd):
                self.stop.clear()
                self.poll.reset_mock()
                self.events.next.reset_mock()
                self.poll.return_value = pd
                self.run_policy()
                self.events.next.assert_called_once_with(None)
                self.poll.assert_called_once_with()
                self.assert_no_power_write()

    def test_unplugged_boot_then_attach_and_5_to_12v_negotiation(self):
        for boot in ({}, self.detached, self.five):
            with self.subTest(boot=boot):
                self.stop.clear()
                self.sink.reset_mock()
                self.charge.reset_mock()
                self.poll.side_effect = [boot, self.twelve] if boot == self.five else [boot, self.five, self.twelve]
                self.events.next.side_effect = lambda timeout: self.event()
                self.run_policy()
                self.sink.select.assert_called_once_with(hp.profile(self.five))
                self.charge.assert_called_once()

    def test_full_boot_then_real_detach_and_attach_can_charge(self):
        self.poll.side_effect = [self.five, self.twelve]
        self.pack.side_effect = [self.full, self.full, self.full, self.hungry, self.hungry]
        self.events.next.side_effect = [self.event(detached=True), self.event()]
        self.run_policy()
        self.charge.assert_called_once()

    def test_duplicate_attach_after_full_does_not_start_a_charge(self):
        self.poll.return_value = self.five
        self.pack.return_value = self.full
        edges = [self.event()]
        self.events.next.side_effect = lambda timeout: edges.pop() if edges else self.finish(timeout)
        self.run_policy()
        self.poll.assert_called_once_with()
        self.assert_no_power_write()

    def test_negotiation_timeout_does_not_retry_or_charge(self):
        self.poll.return_value = self.five
        def deadline(timeout):
            self.assertEqual(timeout, 10)
            self.clock += timeout
            return None
        self.events.next.side_effect = deadline
        with self.assertRaisesRegex(cs.StopCharge, "timed out"):
            self.run_policy()
        self.sink.select.assert_called_once()
        self.charge.assert_not_called()
        self.chip.set_current.assert_not_called()

    def test_ready_without_an_extra_irq_is_read_at_negotiation_deadline(self):
        self.poll.side_effect = [dict(self.five, requested_mV=None), self.twelve]
        def deadline(timeout):
            self.clock += timeout
            return None
        self.events.next.side_effect = deadline
        self.run_policy()
        self.charge.assert_called_once()

    def test_unstable_boot_that_settles_detached_returns_to_idle(self):
        self.poll.side_effect = [dict(self.detached, stable_state=False), self.detached]
        waits = []
        def next_event(timeout):
            waits.append(timeout)
            if timeout is None:
                return self.finish(timeout)
            self.clock += timeout
            return None
        self.events.next.side_effect = next_event
        self.run_policy()
        self.assertEqual(waits, [10, None])
        self.assert_no_power_write()

    def test_rejects_source_roles_bad_contracts_and_missing_12v_pdo(self):
        for pd in (dict(self.five, state_hex="39ff2415"), dict(self.five, source=True),
                   dict(self.five, requested_mA=500), dict(self.five, requested_mV=9000),
                   dict(self.five, caps_hex="00" * 32)):
            with self.subTest(pd=pd):
                self.poll.return_value = pd
                with self.assertRaises(cs.StopCharge):
                    self.run_policy()
                self.assert_no_power_write()

    def test_full_is_not_a_bypass_for_battery_faults_or_nonzero_target(self):
        for flags, current in ((0x40e1, 0), (0x50e0, 0), (0x40e0, 3776)):
            with self.subTest(flags=flags, current=current):
                self.pack.return_value = dict(self.full, flags=flags)
                self.regs[0x14] = current
                with self.assertRaises(cs.StopCharge):
                    self.run_policy()
                self.assert_no_power_write()

    def test_nonfull_8400mv_is_not_changed_before_a_12v_contract(self):
        self.poll.return_value = self.five
        self.regs[0x15] = 8400
        with patch.object(hp, "send") as send:
            self.run_policy()
        self.sink.select.assert_called_once()
        send.assert_not_called()
        self.chip.set_current.assert_not_called()
        self.charge.assert_not_called()
        self.assertEqual(self.regs[0x15], 8400)

    def test_5v_active_firmware_target_is_not_renegotiated(self):
        self.poll.return_value = self.five
        self.regs[0x14] = 3776
        self.pack.return_value = dict(self.hungry, flags=0x80, current_now=900000)
        with self.assertRaisesRegex(cs.StopCharge, "active charge on the 5 V"):
            self.run_policy()
        self.assert_no_power_write()

    def test_stop_before_negotiation_prevents_select(self):
        self.poll.return_value = self.five
        self.sink.check.side_effect = lambda *a: self.stop.set()
        self.run_policy()
        self.assert_no_power_write()

    def test_full_replug_restores_input_without_writing_charge_current_or_voltage(self):
        self.regs.update({0x15: 8400, 0x20: 0, 0x22: 0x4100, 0x3f: 0x4100})
        self.pack.return_value = self.full
        self.poll.side_effect = [self.five, self.twelve, self.twelve]
        self.sink.switches.return_value = 0
        edges = [self.event()]
        self.events.next.side_effect = lambda timeout: edges.pop() if edges else self.finish(timeout)
        def consumer(on):
            self.sink.switches.return_value = int(on)
            self.regs[0x20] = 0x8000 if on else 0
        self.sink.consumer.side_effect = consumer
        def limit(chip, payload):
            self.assertEqual(payload, bytes.fromhex("3f 00 3c"))
            self.regs[0x3f] = self.regs[0x22] = 0x3c00
        with patch.object(hp, "send", side_effect=limit) as send:
            self.run_policy()
        self.sink.select.assert_called_once_with(hp.profile(self.five))
        self.assertEqual([c.args for c in self.sink.consumer.call_args_list], [(True,), (False,)])
        send.assert_called_once()
        self.chip.set_current.assert_not_called()
        self.charge.assert_not_called()
        self.assertEqual((self.regs[0x14], self.regs[0x15]), (0, 8400))

    def test_full_input_cannot_replace_another_power_path(self):
        self.pack.return_value = self.full
        self.sink.switches.return_value = 0
        with self.assertRaisesRegex(cs.StopCharge, "different path"):
            self.run_policy()
        self.assert_no_power_write()

    def test_full_input_rechecks_battery_before_opening_switch(self):
        self.pack.side_effect = [self.full, self.full, self.hungry]
        self.regs[0x20] = 0
        self.sink.switches.return_value = 0
        with self.assertRaisesRegex(cs.StopCharge, "before input enable"):
            self.run_policy()
        self.assert_no_power_write()

    def test_full_input_write_failure_closes_only_owned_consumer(self):
        self.pack.return_value = self.full
        self.regs[0x20] = 0
        self.sink.switches.return_value = 0
        self.sink.consumer.side_effect = [OSError("switch readback failed"), None]
        with self.assertRaisesRegex(OSError, "switch readback failed"):
            self.run_policy()
        self.assertEqual([c.args for c in self.sink.consumer.call_args_list], [(True,), (False,)])
        self.chip.set_current.assert_not_called()

    def test_8400mv_is_accepted_only_for_zero_current_standby(self):
        self.regs[0x15] = 8400
        self.chip.settings(0, voltage=8400)
        for expected, voltage in ((1024, 8400), (0, 8800)):
            with self.assertRaisesRegex(cs.StopCharge, "unsupported voltage"):
                self.chip.settings(expected, voltage=voltage)
        with self.assertRaisesRegex(cs.StopCharge, "voltage limit"):
            self.chip.settings(0)

    def test_reset_voltage_is_initialized_only_after_contract_and_pack_checks(self):
        self.regs[0x15] = 8400
        def write(chip, payload):
            self.assertEqual(payload, bytes.fromhex("15 38 22"))
            self.assertEqual(self.regs[0x14], 0)
            self.sink.check.assert_called_with(hp.profile(self.twelve), 12000)
            self.regs[0x15] = 8760
        with patch.object(hp, "send", side_effect=write) as send:
            self.run_policy()
        send.assert_called_once()
        self.charge.assert_called_once()

    def test_voltage_init_refuses_full_faults_bad_requests_and_unknown_settings(self):
        for battery, change in (
                (self.full, {}), (dict(self.hungry, flags=0x81), {}),
                (dict(self.hungry, temp=401), {}),
                (dict(self.hungry, constant_charge_voltage_max=8500000), {}),
                (dict(self.hungry, voltage_now=8800000), {}),
                (self.hungry, {0x15: 8504}), (self.hungry, {0x14: 3776}),
                (self.hungry, {0x3f: 0}), (self.hungry, {0x20: 0x8080})):
            with self.subTest(battery=battery, change=change), patch.dict(self.regs, {0x15: 8400, **change}):
                self.pack.return_value = battery
                with patch.object(hp, "send") as send, self.assertRaises(cs.StopCharge):
                    cs.initialize_voltage(self.sink, self.chip, hp.profile(self.twelve))
                send.assert_not_called()

    def test_voltage_readback_failure_prevents_charge_handoff(self):
        self.regs[0x15] = 8400
        with patch.object(hp, "send") as send, self.assertRaisesRegex(cs.StopCharge, "voltage limit"):
            self.run_policy()
        send.assert_called_once()
        self.charge.assert_not_called()
        self.chip.set_current.assert_not_called()

    def test_voltage_init_rejects_another_input_path(self):
        self.regs[0x15] = 8400
        self.sink.switches.return_value = 0
        with patch.object(hp, "send") as send, self.assertRaisesRegex(cs.StopCharge, "different path"):
            self.run_policy()
        send.assert_not_called()

    def test_voltage_init_does_not_write_after_stop(self):
        self.regs[0x15] = 8400
        self.stop.set()
        with patch.object(hp, "send") as send:
            cs.initialize_voltage(self.sink, self.chip, hp.profile(self.twelve))
        send.assert_not_called()

    def test_unplugged_firmware_voltage_is_preserved(self):
        self.regs.update({0x15: 8696, 0x3f: 0x0900, 0x22: 0x0900})
        with patch.object(hp, "send") as send:
            self.run_policy()
        send.assert_not_called()
        self.charge.assert_called_once_with(self.sink, self.chip, hp.profile(self.twelve),
                                       wait=self.events.wait_charging, initial_current=0, voltage=8696, on_full=ANY)

    def test_inactive_unplugged_firmware_target_is_cleared_before_negotiation(self):
        self.regs.update({0x14: 2880, 0x15: 8696, 0x20: 0, 0x3f: 0x0900, 0x22: 0x0900})
        self.poll.side_effect = [self.five, self.twelve]
        self.events.next.side_effect = lambda timeout: self.event()
        self.chip.set_current.side_effect = lambda ma: self.regs.__setitem__(0x14, ma)
        self.run_policy()
        self.chip.set_current.assert_called_once_with(0)
        self.sink.select.assert_called_once_with(hp.profile(self.twelve))
        self.charge.assert_called_once_with(self.sink, self.chip, hp.profile(self.twelve),
                                       wait=self.events.wait_charging, initial_current=0, voltage=8696, on_full=ANY)

    def test_observed_usb_input_limit_can_be_updated_with_current_zero(self):
        self.regs.update({0x15: 8696, 0x3f: 0x0900, 0x22: 0x0900})
        def limit(chip, payload):
            self.assertEqual(payload, bytes.fromhex("3f 00 3c"))
            self.regs[0x3f] = self.regs[0x22] = 0x3c00
        with patch.object(hp, "send", side_effect=limit) as send:
            self.chip.limit_input(voltage=8696)
        send.assert_called_once()
        self.assertEqual((self.regs[0x14], self.regs[0x15]), (0, 8696))


if __name__ == "__main__":
    unittest.main()

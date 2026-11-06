#!/usr/bin/env python3
"""Exercise the opt-in charger gates and transfer format without hardware."""
from contextlib import ExitStack, nullcontext
import importlib.util
from pathlib import Path
import sys
from tempfile import TemporaryDirectory, TemporaryFile
import unittest
from unittest.mock import Mock, patch

src = Path(__file__).resolve().parent
for name, path in (("np545_charge_observe", src / "probe-debian-charge.py"),
                   ("keepcharge", src / "debian-battery/keepcharge.py"),
                   ("hotplug", src / "debian-battery/hotplug.py")):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)

import keepcharge as kc
import hotplug as hp


class KeepaliveTests(unittest.TestCase):
    def setUp(self):
        self.regs = {0xfe: 0x40, 0xff: 0x89, 0x12: 0xe70e, 0x15: 8760,
                     0x22: 0x3c00, 0x3f: 0x3c00, 0x14: 3776}
        self.chip = kc.Charger.__new__(kc.Charger)
        self.chip.word = self.regs.__getitem__
        self.pd = dict(requested_mV=12000, requested_mA=3000)
        self.pack = dict(flags=0x80, temp=274, capacity=90, voltage_now=8640000,
                         constant_charge_voltage_max=8860000, constant_charge_current_max=4256000,
                         current_now=1200000)

    def decide(self, expected=3776):
        return kc.target(self.pd, self.pack, self.chip, expected)

    def test_current_cap_and_round_down(self):
        self.assertEqual(self.decide(), 1024)
        self.pack["constant_charge_current_max"] = 987000
        self.assertEqual(self.decide(), 960)

    def test_stop_conditions(self):
        for obj, key, bad_values in (
                (self.pd, "requested_mV", [5000, None]), (self.pd, "requested_mA", [500]),
                (self.pack, "flags", [0, 0x81, 0xa0, 0xc0, 0x4080, 0x1080, 0x8080]),
                (self.pack, "temp", [49, 401]), (self.pack, "capacity", [100]),
                (self.pack, "current_now", [0, -9000]), (self.pack, "voltage_now", [8900000]),
                (self.pack, "constant_charge_current_max", [0, 63000, 65535000]),
                (self.pack, "constant_charge_voltage_max", [8500000, 65535000]),
                (self.regs, 0xff, [0]), (self.regs, 0x12, [0xe70f, 0xe72e, 0x870e]),
                (self.regs, 0x14, [0, 2048]), (self.regs, 0x15, [8800]),
                (self.regs, 0x22, [0]), (self.regs, 0x3f, [0])):
            for value in bad_values:
                with self.subTest(key=key, value=value), patch.dict(obj, {key: value}):
                    with self.assertRaises(kc.StopCharge):
                        self.decide()

    def test_wire_format_and_readback(self):
        self.chip.address = 9
        self.chip.fd = 123

        def transfer(fd, ioctl, arg):
            self.assertEqual((fd, ioctl, arg.count), (123, 0x0707, 1))
            msg = arg.messages[0]
            self.assertEqual((msg.address, msg.flags, msg.length), (9, 0, 3))
            self.assertEqual(bytes(msg.buffer[:3]), bytes([0x14, 0, 4]))
            return 1

        self.regs[0x14] = 1024
        with patch.object(kc.fcntl, "ioctl", transfer):
            self.chip.set_current(1024)
            self.regs[0x14] = 0
            with self.assertRaises(OSError):
                self.chip.set_current(1024)
        with self.assertRaises(ValueError):
            self.chip.set_current(3776)

    def test_one_shot_lifecycle(self):
        for end in ("shutdown", "pd_loss", "hardware_cutoff", "readback_failed",
                    "missed_deadline", "late_boot", "read_only_entry"):
            with self.subTest(end=end), TemporaryDirectory() as tmp, ExitStack() as stack:
                root = Path(tmp)
                cmdline = root / "cmdline"
                args = "np545.battery=1"
                if end != "read_only_entry":
                    args += " np545.keepcharge=1"
                cmdline.write_text(args)
                (root / "compatible").write_bytes(b"samsung,np545xla\0qcom,sc8180x\0")
                (root / "device").mkdir()
                (root / "device/sbs_status").touch()
                claim = root / "claimed"
                paths = {"/proc/cmdline": cmdline, "/run/np545-keepcharge.claimed": claim}
                clock = [95 if end == "late_boot" else 20]
                writes = []
                regs = self.regs.copy()
                chip = Mock(word=regs.__getitem__)

                def write(ma):
                    writes.append(ma)
                    regs[0x14] = ma
                    if end == "readback_failed" and ma:
                        raise OSError("failed after writing")

                def wait(_):
                    clock[0] += 91 if end == "missed_deadline" else 46
                    if end == "hardware_cutoff":
                        regs[0x14] = 0
                    if end == "shutdown" and len(writes) == 2:
                        stop.set()

                stop = kc.threading.Event()
                chip.set_current.side_effect = write
                for key, value in dict(Path=lambda path: paths[path], BATTERY=root, DT=root,
                                       uptime=lambda: clock[0], stopping=stop, pack=lambda: self.pack,
                                       port=lambda _: {} if end == "pd_loss" and writes else self.pd,
                                       Charger=lambda: nullcontext(chip), log=Mock()).items():
                    stack.enter_context(patch.object(kc, key, value))
                stack.enter_context(patch.object(stop, "wait", wait))
                if end == "shutdown":
                    kc.run()
                    self.assertEqual(writes, [1024, 1024, 0])
                else:
                    with self.assertRaises((kc.StopCharge, OSError)):
                        kc.run()
                    initial_refusal = end in ("late_boot", "read_only_entry")
                    self.assertEqual(writes, [] if initial_refusal else [1024, 0])
                    self.assertEqual(claim.exists(), not initial_refusal)
                if claim.exists():
                    # Even if the firmware settings reappear, a second start in the
                    # same boot must refuse before a nonzero write.
                    stop.clear()
                    clock[0] = 30
                    regs[0x14] = 3776
                    with patch.object(kc, "port", return_value=self.pd), self.assertRaises(FileExistsError):
                        kc.run()

class HotplugTests(unittest.TestCase):
    # The same physical source sends an extra PPS object after reconnection.
    five = dict(requested_mV=5000, requested_mA=3000, selected_pdo=1, state_hex="19ff2415",
                caps_hex="a16f00002c91010a2cd102002cc103002cb104002c4106003c21a4c900000000")
    twelve = dict(five, requested_mV=12000, selected_pdo=3,
                  caps_hex="615100002c91010a2cd102002cc103002cb104002c4106000000000000000000")

    def test_select_only_live_fixed_board_profile(self):
        known = hp.profile(self.twelve)
        self.assertEqual(hp.profile(self.five), known)
        sink = hp.Sink.__new__(hp.Sink)
        lock_file = TemporaryFile()
        self.addCleanup(lock_file.close)
        sink.fd = lock_file.fileno()
        sink.word = {0x20: 0x19ff2415, 0x60: 0xa0}.__getitem__
        with patch.object(hp, "port", return_value=self.five), patch.object(hp, "send") as send:
            sink.select(known)
            self.assertEqual([args[0][1].hex() for args in send.call_args_list],
                             ["0010030303", "0010030213"])
        for pd, lp in [(dict(self.five, requested_mV=None), 0xa0),
                       (dict(self.five, state_hex="39ff2415"), 0xa0),
                       (dict(self.five, caps_hex="00"*32), 0xa0), (self.five, 0xa8),
                       (self.five, 0xe0), (self.five, 0)]:
            sink.word = {0x20: 0x19ff2415, 0x60: lp}.__getitem__
            with patch.object(hp, "port", return_value=pd), patch.object(hp, "send") as send:
                with self.assertRaises(hp.StopCharge):
                    sink.select(known)
                send.assert_not_called()

    def test_no_implicit_input_or_charge(self):
        sink, chip = Mock(), Mock()
        known = hp.profile(self.twelve)
        battery = dict(flags=0xc0, capacity=93, temp=301, voltage_now=8450000,
                       constant_charge_voltage_max=8860000, constant_charge_current_max=4256000,
                       current_now=-810000)
        self.assertEqual(hp.pack_target(battery, starting=True), 1024)
        with self.assertRaises(hp.StopCharge):
            hp.pack_target(battery)
        for flags in (0x20, 0xa0, 0x4080, 0x1080, 0x81):
            with self.assertRaises(hp.StopCharge):
                hp.pack_target(dict(battery, flags=flags), starting=True)
        with patch.object(hp, "pack", return_value=battery), patch.object(hp, "log"):
            sink.switches.return_value = 0
            chip.input_present.return_value = True
            with self.assertRaisesRegex(hp.StopCharge, "different path"):
                hp.charge_after_replug(sink, chip, known)
            chip.set_current.assert_not_called()
            sink.consumer.assert_not_called()
            chip.input_present.return_value = False
            with patch.object(hp, "wait_for", side_effect=hp.StopCharge("no AC")), patch.object(
                    hp, "poll_port", return_value=dict(attached=True, source=False)):
                with self.assertRaisesRegex(hp.StopCharge, "no AC"):
                    hp.charge_after_replug(sink, chip, known)
            self.assertEqual([x.args for x in sink.consumer.call_args_list], [(True,), (False,)])
            chip.set_current.assert_not_called()

    def test_recovered_current_window_and_stop(self):
        for begins_charging in (True, False):
            sink, chip = Mock(), Mock()
            chip.input_present.return_value = True
            sink.switches.return_value = 1
            now = [0]
            stop = hp.stopping.__class__()
            connected = dict(stable_state=True, pd_state=21, attached=True, source=False)
            writes = []
            chip.set_current.side_effect = lambda ma: writes.append((now[0], ma))

            def tick(seconds):
                now[0] += seconds
                if now[0] >= 181:
                    stop.set()

            def pack():
                positive = begins_charging and now[0] > 1
                return dict(current_now=900000 if positive else -50000,
                            flags=0x80 if positive else 0xc0, capacity=95,
                            temp=300, voltage_now=8593000, constant_charge_voltage_max=8860000,
                            constant_charge_current_max=4256000)

            with self.subTest(begins_charging=begins_charging), ExitStack() as stack:
                for name, value in dict(stopping=stop, pack=pack, uptime=lambda: now[0],
                                        poll_port=lambda: connected, log=Mock()).items():
                    stack.enter_context(patch.object(hp, name, value))
                stack.enter_context(patch.object(stop, "wait", tick))
                if begins_charging:
                    hp.charge_after_replug(sink, chip, hp.profile(self.twelve))
                    self.assertEqual(writes, [(0, 1024), (45, 1024), (90, 1024), (135, 1024),
                                              (180, 1024), (181, 0)])
                else:
                    with self.assertRaisesRegex(hp.StopCharge, "did not begin"):
                        hp.charge_after_replug(sink, chip, hp.profile(self.twelve))
                    self.assertEqual(writes, [(0, 1024), (10, 0)])

    def test_acknowledged_detach_only_after_current_connection(self):
        with TemporaryDirectory() as tmp:
            evidence = Path(tmp) / "last-detach"
            evidence.write_text("1000 150933760")  # explicit detached 0x08ff1100
            with ExitStack() as stack:
                stack.enter_context(patch.object(hp, "ACK_DETACH", evidence))
                stack.enter_context(patch.object(hp, "poll_port", return_value={}))
                stack.enter_context(patch.object(hp, "pack", return_value={"current_now": -800000}))
                stack.enter_context(patch.object(hp.time, "CLOCK_BOOTTIME", 7, create=True))
                stack.enter_context(patch.object(hp.time, "clock_gettime_ns", return_value=1100))
                self.assertTrue(hp.detached_since(900, True))
                self.assertFalse(hp.detached_since(1000, True))
                self.assertFalse(hp.detached_since(900, False))
                with patch.object(hp, "poll_port", return_value=dict(state_hex="19ff2415")):
                    self.assertFalse(hp.detached_since(900, True))
                with patch.object(hp, "pack", return_value={"current_now": 1}):
                    self.assertFalse(hp.detached_since(900, True))

    def test_no_charge_during_detach_transition(self):
        sink = hp.Sink.__new__(hp.Sink)
        for raw in ("08ff1100", "09ff2400", "19ff2415"):
            with patch.object(hp, "port", return_value=dict(state_hex=raw)):
                self.assertIsNone(sink.check((3, 0), 12000, allow_detach=True))
                with self.assertRaises(hp.StopCharge):
                    sink.check((3, 0), 12000)
        with patch.object(hp, "port", return_value=dict(state_hex="39ff2415")):
            with self.assertRaises(hp.StopCharge):
                sink.check((3, 0), 12000, allow_detach=True)

    def test_disconnect_requires_real_state(self):
        self.assertFalse(hp.is_detached({}))
        self.assertFalse(hp.is_detached(dict(stable_state=False)))
        self.assertFalse(hp.is_detached(dict(stable_state=True, pd_state=21, attached=True, source=False)))
        self.assertTrue(hp.is_detached(dict(stable_state=True, pd_state=0, attached=False, source=False)))


if __name__ == "__main__":
    unittest.main()

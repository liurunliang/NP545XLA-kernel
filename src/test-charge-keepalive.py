#!/usr/bin/env python3
"""Exercise the opt-in charger gates and transfer format without hardware."""
from contextlib import ExitStack, nullcontext
import importlib.util
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

src = Path(__file__).resolve().parent
for name, path in (("np545_charge_observe", src / "probe-debian-charge.py"),
                   ("keepcharge", src / "debian-battery/keepcharge.py")):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)

import keepcharge as kc


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


if __name__ == "__main__":
    unittest.main()

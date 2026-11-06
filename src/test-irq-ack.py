#!/usr/bin/env python3
"""Exercise the installed IC10 acknowledgment code without opening a device."""
import errno
import fcntl
import os
from pathlib import Path
from tempfile import NamedTemporaryFile, TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

from gpiod.line import Value
import irq_ack as ack


class AckTests(unittest.TestCase):
    def setUp(self):
        self.file = NamedTemporaryFile()
        self.addCleanup(self.file.close)
        self.chip = Mock(fd=self.file.fileno())
        self.chip.word.side_effect = {0x20: 0x19ff2415, 0x60: 0xa0}.__getitem__
        self.chip.read.side_effect = {0x30: bytes(range(48)), 0x08: b'\0'}.__getitem__
        self.line = Mock()
        self.line.get_value.side_effect = [Value.INACTIVE, Value.INACTIVE, Value.ACTIVE]
        self.send = self.enterContext(patch.object(ack, "send"))
        self.log = self.enterContext(patch.object(ack.trace, "log"))

    def test_snapshot_before_only_clear_and_readback(self):
        def check_locked(chip, data):
            self.assertIs(chip, self.chip)
            self.assertEqual(data, b"\x00\x10\x01")
            self.assertEqual([c.args[0] for c in chip.read.call_args_list], [0x30]+[8]*5)
            fd = os.open(self.file.name, os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(fd)
        self.send.side_effect = check_locked
        ack.acknowledge(self.chip, self.line, 4)
        self.assertEqual(self.send.call_count, 1)
        self.assertEqual(self.log.call_args.kwargs["after"], 1)
        self.assertEqual(self.log.call_args.kwargs["seq"], 4)

    def test_high_line_or_released_before_write(self):
        for levels in ([Value.ACTIVE], [Value.INACTIVE, Value.ACTIVE]):
            self.line.get_value.side_effect = levels
            ack.acknowledge(self.chip, self.line, 1)
        self.send.assert_not_called()

    def test_fault_or_unreadable_status(self):
        with patch.object(self.chip, "word", side_effect={0x20: 0x39ff2415, 0x60: 0xa0}.__getitem__):
            with self.assertRaises(RuntimeError):
                ack.acknowledge(self.chip, self.line, 1)
        self.chip.read.side_effect = OSError(errno.ENXIO, "not responding")
        with self.assertRaises(OSError):
            ack.acknowledge(self.chip, self.line, 1)
        self.send.assert_not_called()

    def test_publish_only_a_twice_observed_detach(self):
        for final, saved in [(0x08ff4400, True), (0x19ff2415, False)]:
            with self.subTest(final=final), TemporaryDirectory() as tmp:
                stamp = Path(tmp) / "detached"
                self.chip.word.side_effect = [0x08ff1100, 0xa0, final]
                self.line.get_value.side_effect = [Value.INACTIVE, Value.INACTIVE, Value.ACTIVE]
                with patch.object(ack, "ACK_DETACH", stamp):
                    ack.acknowledge(self.chip, self.line, 2)
                self.assertEqual(stamp.exists(), saved)
                if saved:
                    timestamp, state = map(int, stamp.read_text().split())
                    self.assertEqual(state, 0x08ff1100)
                    self.assertEqual(timestamp, self.log.call_args.kwargs['write_start_ns'])

    def test_stuck_low_does_not_repeat_write(self):
        self.line.get_value.side_effect = None
        self.line.get_value.return_value = Value.INACTIVE
        ack.acknowledge(self.chip, self.line, 1)
        self.assertEqual(self.send.call_count, 1)
        self.log.assert_called_with("release-unconfirmed", seq=1)


if __name__ == "__main__":
    unittest.main()

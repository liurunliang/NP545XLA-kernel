#!/usr/bin/env python3
"""Check rejection of unsafe stage inputs without touching system power state."""
import copy
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('probe-debian-pm-stage.py')
spec = importlib.util.spec_from_file_location('pm_stage', SCRIPT)
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class Guards(unittest.TestCase):
    def setUp(self):
        self.sample = {
            'ic10': {'stable_state': True, 'attached': True, 'source': False, 'pd_state': 21,
                     'requested_mV': 5000, 'requested_mA': 3000,
                     'caps_hex': '615100002c91010a2cd102002cc103002cb104002c4106000000000000000000'},
            'charger': {'manufacturer': 64, 'part': 137,
                        'raw': {'12': 0xe70e, '14': 0, '15': 8400, '22': 0x3c00, '3f': 0x3c00}},
            'battery': {'capacity': 100, 'status': 'Full', 'current_now': 0, 'voltage_now': 8666000},
            'temperature': 291, 'sbs_status': 0x40e0}

    def test_measured_full_baseline_is_accepted(self):
        self.assertEqual(stage.validate_power(self.sample)['voltage_mV'], 8400)

    def test_nonzero_charger_target_is_rejected_even_if_battery_current_is_zero(self):
        self.sample['charger']['raw']['14'] = 1024
        with self.assertRaises(RuntimeError):
            stage.validate_power(self.sample)

    def test_full_flag_with_small_negative_current_is_accepted(self):
        self.sample['battery'].update(status='Discharging', current_now=-6000)
        stage.validate_power(self.sample)
        self.sample['sbs_status'] = 0x40c0
        with self.assertRaises(RuntimeError):
            stage.validate_power(self.sample)
        self.sample['sbs_status'] = 0x40e0
        self.sample['battery']['current_now'] = -500000
        with self.assertRaises(RuntimeError):
            stage.validate_power(self.sample)

    def test_unknown_power_states_are_rejected(self):
        cases = [('ic10', 'attached', False), ('ic10', 'source', True),
                 ('ic10', 'stable_state', False), ('ic10', 'requested_mV', 15000),
                 ('ic10', 'requested_mA', 2000), ('ic10', 'caps_hex', '00'*32),
                 ('charger', 'part', 0), ('battery', 'capacity', 95),
                 ('battery', 'current_now', 1000000), ('battery', 'status', 'Charging')]
        for section, key, value in cases:
            with self.subTest(section=section, key=key):
                sample = copy.deepcopy(self.sample); sample[section][key] = value
                with self.assertRaises(RuntimeError):
                    stage.validate_power(sample)

    def test_pack_fault_and_temperature_are_rejected(self):
        for key, value in [('temperature', 401), ('temperature', 49),
                           ('sbs_status', 0xc0e0), ('sbs_status', 0x40c0)]:
            with self.subTest(key=key, value=value):
                sample = copy.deepcopy(self.sample); sample[key] = value
                with self.assertRaises(RuntimeError):
                    stage.validate_power(sample)

    def test_later_or_real_sleep_modes_cannot_be_selected(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)/'must-not-exist'
            for mode in ('none', 'platform', 'processors', 'core', 'mem'):
                p = subprocess.run([sys.executable, str(SCRIPT), '--stage', mode,
                                    '--expected-boot', 'unused', '--output', str(out)],
                                   capture_output=True, text=True)
                self.assertEqual(p.returncode, 2)
                self.assertIn('invalid choice', p.stderr)
                self.assertFalse(out.exists())

    def test_release_requires_both_pinmux_and_gpio_character_device(self):
        self.assertTrue(stage.is_gpio_released('UNCLAIMED', False, None))
        self.assertFalse(stage.is_gpio_released('UNCLAIMED', True, None))
        self.assertFalse(stage.is_gpio_released('UNCLAIMED', False, 'np545-gpiocharge'))
        self.assertFalse(stage.is_gpio_released('GPIO 3100000.pinctrl:645', False, None))

    def test_journal_delivery_may_lag_behind_running_service(self):
        s = {'ActiveState': 'active', 'MainPID': '42', 'InvocationID': 'a'*32, 'NRestarts': '0'}
        with patch.object(stage, 'service', return_value=s), patch.object(stage.time, 'sleep'), \
                patch.object(stage, 'command', side_effect=['', '', '{"event": "full-wait"}']) as command:
            stage.wait_full_wait(s)
        self.assertEqual(command.call_count, 3)
        self.assertTrue(all(c.args[0] == 'journalctl' for c in command.call_args_list))

    def test_old_invocation_cannot_confirm_new_service(self):
        s = {'ActiveState': 'active', 'MainPID': '42', 'InvocationID': 'a'*32, 'NRestarts': '0'}
        with patch.object(stage, 'service', return_value={**s, 'InvocationID': 'b'*32}), \
                patch.object(stage, 'command') as command:
            with self.assertRaises(RuntimeError):
                stage.wait_full_wait(s)
        command.assert_not_called()

    def test_missing_journal_confirmation_has_a_deadline(self):
        s = {'ActiveState': 'active', 'MainPID': '42', 'InvocationID': 'a'*32, 'NRestarts': '0'}
        with patch.object(stage, 'service', return_value=s), \
                patch.object(stage.time, 'monotonic', side_effect=[0, 11]), \
                patch.object(stage, 'command', return_value=''):
            with self.assertRaises(RuntimeError):
                stage.wait_full_wait(s)


if __name__ == '__main__':
    unittest.main()

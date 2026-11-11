#!/usr/bin/env python3
"""Exercise status provenance, freshness and unit mapping without hardware."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

src = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('reporter', src / 'debian-battery/power_supply_report.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.pd = dict(stable_state=True, source=False, attached=True, pd_state=21,
                       state_hex='19ff2415', requested_mV=12000, requested_mA=3000)
        self.chip = dict(manufacturer=64, part=137, current_setting_mA=1024,
                         voltage_setting_mV=8696,
                         raw={'12': 0xe70e, '14': 1024, '15': 8696, '22': 0x3c00, '3f': 0x3c00})
        self.proof = dict(event='refresh', boottime=100.0, ac=True, readback_mA=1024)

    def row(self, event=None, **fields):
        return dict(_BOOT_ID='abcd', _SYSTEMD_INVOCATION_ID='invocation',
                    _SYSTEMD_UNIT=r.SERVICE, _UID='0', _TRANSPORT='stdout',
                    MESSAGE=json.dumps(self.proof if event is None else event), **fields)

    def mapped(self):
        return r.map_state(self.pd, self.chip, self.proof)

    def test_units_and_actual_target(self):
        self.assertEqual(self.mapped(), (7, 1, 12000000, 3000000, 3000000, 1024000, 8696000))

    def test_full_input_5v_is_online_without_claiming_charge_current(self):
        self.pd['requested_mV'] = 5000
        self.chip.update(current_setting_mA=0, voltage_setting_mV=8400)
        self.chip['raw'].update({'14': 0, '15': 8400})
        self.proof = dict(event='full-sample', readback_mA=0)
        self.assertEqual(self.mapped(), (7, 1, 5000000, 3000000, 3000000, 0, 8400000))

    def test_contract_does_not_prove_input_path(self):
        self.proof = None
        self.assertEqual(self.mapped(), (0,) * 7)

    def test_live_detach_discards_retained_contract_and_settings(self):
        self.pd.update(attached=False, pd_state=0, state_hex='08ff1100')
        self.assertEqual(self.mapped(), (1, 0, 0, 0, 0, 0, 0))

    def test_pd_transitions_roles_and_unknown_adapters_are_unknown(self):
        for change in ({'stable_state': False}, {'source': True}, {'attached': False},
                       {'pd_state': 5}, {'state_hex': 'f9ff2415'},
                       {'requested_mV': 9000}, {'requested_mA': 2000}, {'error': 'NACK', 'stable_state': False}):
            with self.subTest(change=change):
                pd = dict(self.pd, **change)
                self.assertEqual(r.map_state(pd, self.chip, self.proof), (0,) * 7)

    def test_no_nack_as_unplugged(self):
        self.assertEqual(r.map_state({'error': 'NACK'}, {}, None), (0,) * 7)

    def test_charger_validation(self):
        for key, value in [('manufacturer', 0), ('part', 0), ('error', 'bad'),
                           ('current_setting_mA', 1025), ('current_setting_mA', -64),
                           ('current_setting_mA', 1088), ('voltage_setting_mV', 8400),
                           ('voltage_setting_mV', 9000)]:
            with self.subTest(key=key, value=value):
                self.assertEqual(r.map_state(self.pd, dict(self.chip, **{key: value}), self.proof), (0,) * 7)
        for key in self.chip['raw']:
            chip = copy.deepcopy(self.chip)
            chip['raw'][key] ^= 1
            with self.subTest(register=key):
                self.assertEqual(r.map_state(self.pd, chip, self.proof), (0,) * 7)

    def test_target_change_invalidates_proof(self):
        self.proof['readback_mA'] = 960
        self.assertEqual(self.mapped(), (0,) * 7)

    def test_current_invocation_sample_is_accepted(self):
        self.assertEqual(r.evidence([self.row()], 'ab-cd', 'invocation', 101), self.proof)

    def test_trace_uses_boottime_ns_and_new_sample_supersedes_it(self):
        armed = self.row(dict(event='armed', boottime_ns=90000000000))
        self.assertEqual(r.evidence([armed, self.row()], 'abcd', 'invocation', 101), self.proof)
        edge = self.row(dict(event='edge', boottime_ns=101000000000))
        self.assertIsNone(r.evidence([self.row(), edge], 'abcd', 'invocation', 102))

    def test_millisecond_rounding_after_nanosecond_record_is_accepted(self):
        edge = self.row(dict(event='edge', boottime_ns=100000400000))
        self.assertEqual(r.evidence([edge, self.row()], 'abcd', 'invocation', 101), self.proof)

    def test_stale_future_and_nonfinite_proof(self):
        for stamp in (34, 102, float('nan'), float('inf'), -1, '100', True):
            with self.subTest(stamp=stamp):
                self.assertIsNone(r.evidence([self.row(dict(self.proof, boottime=stamp))], 'abcd', 'invocation', 100))

    def test_foreign_provenance_rejected(self):
        for key in ('_BOOT_ID', '_SYSTEMD_INVOCATION_ID', '_SYSTEMD_UNIT', '_UID'):
            row = self.row()
            row[key] = 'foreign'
            with self.subTest(key=key):
                self.assertIsNone(r.evidence([row], 'abcd', 'invocation', 101))

    def test_new_controller_event_invalidates_positive_proof(self):
        for name in ('stop', 'exit', 'consumer-off', 'detached', 'full-wait', 'unknown-new-version'):
            with self.subTest(event=name):
                self.assertIsNone(r.evidence([self.row(), self.row(dict(event=name, boottime=101))],
                                            'abcd', 'invocation', 102))

    def test_full_sample_requires_zero_target(self):
        for current in (0, 1024):
            event = dict(event='full-sample', boottime=100, readback_mA=current)
            self.assertEqual(r.evidence([self.row(event)], 'abcd', 'invocation', 101),
                             event if current == 0 else None)

    def test_refresh_requires_ac_true(self):
        self.proof['ac'] = False
        self.assertIsNone(r.evidence([self.row()], 'abcd', 'invocation', 101))

    def test_out_of_order_and_malformed_events_rejected(self):
        older = self.row(dict(self.proof, boottime=99))
        malformed = dict(self.row(), MESSAGE='{')
        for tail in (older, malformed, dict(self.row(), MESSAGE='[]')):
            self.assertIsNone(r.evidence([self.row(), tail], 'abcd', 'invocation', 101))

    def test_kernel_frame_size_endianness(self):
        frame = r.encode(self.mapped(), 123456789)
        self.assertEqual(len(frame), 40)
        self.assertEqual(r.FRAME.unpack(frame), (1, 7, 123456789, 1, 12000000, 3000000,
                                                 3000000, 1024000, 8696000))

    def test_source_upgrade_rejected(self):
        with patch.object(Path, 'read_bytes', return_value=b'unknown version'):
            self.assertRaisesRegex(ValueError, 'unreviewed', r.check_sources)


if __name__ == '__main__':
    unittest.main()

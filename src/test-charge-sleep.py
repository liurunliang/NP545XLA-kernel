#!/usr/bin/env python3
"""Exercise retained input, failed preparation and single-use resume handshakes."""
import importlib.util
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

src = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('cycle_fixture', src / 'test-charge-cycle.py')
cycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cycle)
sys.path.insert(0, str(src / 'debian-battery'))
import charge_sleep as sl


class StateFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = self.enterContext(TemporaryDirectory())
        self.root = Path(self.tmp)
        self.boot = self.root / 'boot'
        self.boot.write_text('test-boot')
        self.enterContext(patch.object(sl, 'STATE', self.root))
        self.enterContext(patch.object(sl, 'BOOT', self.boot))
        self.enterContext(patch.object(sl, 'state_directory'))
        self.enterContext(patch.dict(os.environ, INVOCATION_ID='a'*32))
        self.enterContext(patch.object(sl, 'log'))
        self.now = 20
        self.enterContext(patch.object(sl, 'uptime', lambda: self.now))
        self.pause = sl.SleepPause()
        self.pause.ready()

    def request(self):
        record = {**self.pause.identity, 'token': 'c'*32, 'at': self.now}
        sl.write_state('request', record)
        self.pause.request()
        return record


class StateTests(StateFixture):
    def test_ack_cannot_be_published_without_zero_proof(self):
        self.request()
        with self.assertRaisesRegex(sl.StopCharge, 'zero-current proof'):
            self.pause.released()
        self.assertIsNone(sl.read_state('ack'))

    def test_old_boot_wrong_process_stale_time_and_wrong_invocation_rejected(self):
        for change in ({'boot_id':'old'}, {'pid':-1}, {'invocation':'b'*32}, {'at':0}):
            with self.subTest(change=change):
                request = self.request()
                sl.write_state('request', {**request, **change})
                with self.assertRaises(sl.StopCharge):
                    self.pause.request_data()

    def test_new_process_clears_old_handshake_and_close_only_removes_own_identity(self):
        self.request()
        sl.write_state('ack', {'old':True})
        self.pause.ready()
        self.assertIsNone(sl.read_state('request'))
        self.assertIsNone(sl.read_state('ack'))
        sl.write_state('running', {**self.pause.identity, 'pid':-1})
        self.pause.close()
        self.assertEqual(sl.read_state('running')['pid'], -1)

    def test_sleep_mode_requires_systemd_identity(self):
        with patch.dict(os.environ, INVOCATION_ID=''):
            with self.assertRaises(sl.StopCharge):
                sl.SleepPause()


class SleepCycleTests(StateFixture):
    def setUp(self):
        super().setUp()
        self.f = cycle.CycleTests('test_charge_full_wait_recharge_keeps_input_and_lower_voltage')
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.enterContext(patch.object(sl, 'uptime', lambda: self.f.now))
        self.enterContext(patch.object(sl, 'pack', self.f.pack))
        self.f.end = 25
        self.f.after_wait = self.sleep_at_end

    def sleep_at_end(self):
        if self.f.now >= self.f.end:
            self.now = self.f.now
            self.request()

    def retain(self, *args):
        return self.pause.retain(self.f.sink, self.f.chip, *args)

    def active(self):
        self.f.run_cycle(on_sleep=self.retain)
        self.pause.finish(self.f.chip)
        self.assertIsNone(sl.read_state('ack'))  # resource release has not happened
        self.pause.released()

    def test_charging_sleep_zeros_current_and_retains_owned_input(self):
        self.f.timeline = lambda t: self.f.hungry
        self.active()
        self.assertEqual(self.f.writes, [(20,1024),(25,0)])
        self.assertEqual(self.f.switches, [(20,True)])
        self.assertEqual(sl.read_state('ack')['input']['charge_mV'],8696)
        self.assertEqual(sl.read_state('ack')['zero_mA'],0)

    def test_full_wait_sleep_retains_input_and_never_restarts_current(self):
        self.active()
        self.assertEqual(self.f.writes, [(20,1024),(22,0),(25,0)])
        self.assertEqual(self.f.switches, [(20,True)])

    def test_full_5v_inherited_input_and_8400mv_are_retained(self):
        self.f.enabled = True
        self.f.regs.update({0x20:0x8000,0x15:8400})
        self.f.pd.update(requested_mV=5000,selected_pdo=1)
        self.f.timeline = lambda t:self.f.full
        cycle.cs.recover_startup(self.f.events,self.f.sink,self.f.chip,on_sleep=self.retain)
        self.pause.finish(self.f.chip)
        self.pause.released()
        self.assertEqual(self.f.writes,[])
        self.assertEqual(self.f.switches,[])
        self.assertEqual(sl.read_state('ack')['input']['input_mV'],5000)

    def test_full_owned_input_is_retained_by_startup_cleanup(self):
        self.f.timeline = lambda t:self.f.full
        cycle.cs.recover_startup(self.f.events,self.f.sink,self.f.chip,on_sleep=self.retain)
        self.pause.finish(self.f.chip)
        self.pause.released()
        self.assertEqual(self.f.switches,[(20,True)])

    def test_ordinary_stop_still_closes_owned_input(self):
        self.f.after_wait = lambda:None
        self.active()
        self.assertEqual(self.f.switches,[(20,True),(25,False)])
        self.assertIsNone(sl.read_state('ack'))

    def test_missing_request_cannot_retain_input(self):
        self.f.after_wait = lambda:self.pause.request()
        with self.assertRaisesRegex(sl.StopCharge,'sleep request'):
            self.active()
        self.assertEqual(self.f.switches,[(20,True),(25,False)])
        self.assertIsNone(sl.read_state('ack'))

    def test_zero_write_failure_cannot_retain_input(self):
        self.f.timeline = lambda t:self.f.hungry
        write=self.f.chip.set_current
        def fail_zero(ma):
            write(ma)
            if ma==0:raise OSError('zero readback failed')
        self.f.chip.set_current=fail_zero
        with self.assertRaises(OSError):self.active()
        self.assertFalse(self.f.enabled)
        self.assertIsNone(sl.read_state('ack'))

    def test_fault_during_stop_keeps_ordinary_failure_cleanup(self):
        def wait(seconds):
            self.f.now=25
            self.sleep_at_end()
            raise OSError('I2C failure during sleep request')
        self.f.events.wait_charging.side_effect=wait
        with self.assertRaises(OSError):self.active()
        self.assertFalse(self.f.enabled)
        self.assertIsNone(sl.read_state('ack'))

    def test_changed_settings_or_input_prevent_sleep_ack(self):
        for change in ({0x15:8760},{0x20:0},{0x22:0x4100}):
            with self.subTest(change=change):
                self.f.now=20
                self.f.stop.clear()
                self.f.regs.update({0x15:8696,0x20:0,0x22:0x3c00})
                self.f.enabled=False
                self.pause.retained=None
                def mutate():
                    self.sleep_at_end()
                    if self.f.now>=25:self.f.regs.update(change)
                self.f.after_wait=mutate
                with self.assertRaises(sl.StopCharge):self.active()
                self.assertFalse(self.f.enabled)
                self.assertIsNone(sl.read_state('ack'))

    def test_unplugged_known_firmware_preset_is_cleared_before_ack(self):
        self.request()
        self.f.regs[0x14]=2880
        self.pause.finish(self.f.chip)
        self.pause.released()
        self.assertEqual(self.f.writes,[(20,0)])
        self.assertIsNone(sl.read_state('ack')['input'])

    def test_unverified_live_input_cannot_get_ack(self):
        self.request()
        self.f.regs[0x20]=0x8000
        with self.assertRaisesRegex(sl.StopCharge,'not verified'):
            self.pause.finish(self.f.chip)
        self.assertIsNone(sl.read_state('ack'))

    def test_5v_full_to_12v_recharge_then_sleep_uses_current_contract(self):
        self.f.enabled=True
        self.f.regs[0x20]=0x8000
        self.f.pd.update(requested_mV=5000,selected_pdo=1)
        self.f.end=83
        self.f.timeline=lambda t:self.f.full if t<50 else self.f.hungry
        self.f.sink.select.side_effect=lambda known:self.f.pd.update(requested_mV=12000,selected_pdo=3)
        self.f.events.next.side_effect=lambda timeout:Mock(state=0x19ff2415,detached=False)
        cycle.cs.recover_startup(self.f.events,self.f.sink,self.f.chip,on_sleep=self.retain)
        self.pause.finish(self.f.chip)
        self.pause.released()
        self.assertEqual(sl.read_state('ack')['input']['input_mV'],12000)
        self.assertEqual(self.f.switches,[])


class GuardTests(StateFixture):
    def setUp(self):
        super().setUp()
        self.active_state={'ActiveState':'active','MainPID':str(os.getpid()),'InvocationID':'a'*32,
                           'ExecMainStatus':'0','Result':'success'}
        self.inactive={'ActiveState':'inactive','MainPID':'0','InvocationID':'','ExecMainStatus':'0','Result':'success'}
        self.service=self.enterContext(patch.object(sl,'service_state',return_value=self.active_state))
        self.command=self.enterContext(patch.object(sl.subprocess,'run'))
        self.real_zero=sl.verify_zero
        self.zero=self.enterContext(patch.object(sl,'verify_zero'))
        self.enterContext(patch.object(sl.time,'sleep',lambda seconds:setattr(self,'now',self.now+seconds)))

    def stop_and_ack(self,*unused,**kwargs):
        req=sl.read_state('request')
        sl.write_state('ack',{**req,'zero_mA':0,'charge_mV':8696,'input':None,'verified_at':self.now})
        self.service.return_value=self.inactive

    def test_candidate_requires_guard_and_ordering_before_start(self):
        for values, succeeds in ((['np545-charge-sleep-guard.service','sleep.target'],True),
                                 (['','sleep.target'],False),
                                 (['np545-charge-sleep-guard.service',''],False)):
            with self.subTest(values=values), patch.object(sl.subprocess,'check_output',side_effect=values):
                if succeeds:sl.check_enabled()
                else:
                    with self.assertRaises(sl.StopCharge):sl.check_enabled()

    def test_guard_rejects_wrong_charger_identity_before_accepting_zero(self):
        from contextlib import nullcontext
        chip=Mock()
        chip.identify.side_effect=sl.StopCharge('wrong charger')
        with patch.object(sl,'InputCharger',return_value=nullcontext(chip)):
            with self.assertRaises(sl.StopCharge):self.real_zero({'charge_mV':8696})
        chip.settings.assert_not_called()

    def test_successful_prepare_requires_exited_process_and_independent_zero_read(self):
        self.command.side_effect=self.stop_and_ack
        sl.prepare()
        self.zero.assert_called_once()
        self.command.assert_called_once_with(['systemctl','kill','--kill-whom=main','--signal=SIGUSR1',sl.UNIT],check=True,timeout=5)
        self.assertIsNone(sl.read_state('failed'))

    def test_inactive_unready_or_different_process_cannot_receive_signal(self):
        for state in (self.inactive,{**self.active_state,'MainPID':'1'}):
            with self.subTest(state=state):
                self.service.return_value=state
                with self.assertRaises(sl.StopCharge):sl.prepare()
        self.command.assert_not_called()

    def test_failed_zero_check_blocks_prepare_and_prevents_resume(self):
        self.command.side_effect=self.stop_and_ack
        self.zero.side_effect=OSError('zero changed')
        with self.assertRaises(OSError):sl.prepare()
        self.command.reset_mock()
        sl.resume()
        self.command.assert_not_called()

    def test_failed_process_exit_is_not_accepted_even_with_ack(self):
        def fail(*a,**kw):
            self.stop_and_ack()
            self.service.return_value={**self.inactive,'ActiveState':'failed','ExecMainStatus':'1','Result':'exit-code'}
        self.command.side_effect=fail
        with self.assertRaises(sl.StopCharge):sl.prepare()
        self.zero.assert_not_called()

    def test_missing_ack_times_out_and_does_not_restart_faulted_service(self):
        with patch.object(sl,'WAIT_SECONDS',0.1):
            with self.assertRaisesRegex(sl.StopCharge,'timed out'):sl.prepare()
        self.command.reset_mock()
        sl.resume()
        self.command.assert_not_called()

    def test_resume_starts_fresh_process_once_and_consumes_handshake(self):
        self.command.side_effect=self.stop_and_ack
        sl.prepare()
        def start(*a,**kw):
            new={**self.pause.identity,'pid':42,'invocation':'b'*32}
            sl.write_state('running',new)
            self.service.return_value={**self.active_state,'MainPID':'42','InvocationID':'b'*32}
        self.command.reset_mock()
        self.command.side_effect=start
        sl.resume()
        self.command.assert_called_once_with(['systemctl','start','--no-block',sl.UNIT],check=True,timeout=5)
        self.assertIsNone(sl.read_state('ack'))
        sl.resume()
        self.assertEqual(self.command.call_count,1)

    def test_old_boot_or_wrong_nonce_never_restarts(self):
        self.command.side_effect=self.stop_and_ack
        sl.prepare()
        self.command.reset_mock()
        ack=sl.read_state('ack')
        sl.write_state('ack',{**ack,'token':'d'*32})
        sl.resume()
        self.command.assert_not_called()
        sl.write_state('ack',ack)
        self.boot.write_text('next-boot')
        sl.resume()
        self.command.assert_not_called()

    def test_preexisting_new_process_is_never_restarted_by_old_ack(self):
        self.command.side_effect=self.stop_and_ack
        sl.prepare()
        self.command.reset_mock()
        self.service.return_value=self.active_state
        with self.assertRaises(sl.StopCharge):sl.resume()
        self.command.assert_not_called()


if __name__=='__main__':
    unittest.main()

#!/usr/bin/env python3
"""Exercise the missing-log-directory regression with a real systemd manager."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

old, new, output = map(Path, sys.argv[1:])
assert os.geteuid() == 0
output.mkdir()
results = []
for label, source, expected in [('old', old, 209), ('fixed', new, 0)]:
    name = 'np545-passive-logger-validation-' + label
    unit = Path('/run/systemd/system') / (name + '.service')
    logs = Path('/var/log') / name
    assert not unit.exists() and not logs.exists()
    text = source.read_text().replace('np545-passive-charge', name)
    text = '\n'.join(line for line in text.splitlines() if not line.startswith('ConditionKernelCommandLine=')) + '\n'
    text = text.replace('/usr/bin/np545xla-battery-sample --watch', '/usr/bin/printf passive-logger-ok')
    text = text.replace('[Service]\n', '[Service]\nType=oneshot\nRemainAfterExit=yes\n')
    text = text.replace('Restart=on-failure', 'Restart=no')
    unit.write_text(text)
    try:
        subprocess.run(['systemctl', 'daemon-reload'], check=True)
        start = subprocess.run(['systemctl', 'start', unit.name], text=True, capture_output=True)
        raw = subprocess.check_output(['systemctl', 'show', unit.name, '-p', 'Result',
                                       '-p', 'ExecMainStatus', '-p', 'ActiveState'], text=True)
        state = dict(line.split('=', 1) for line in raw.splitlines())
        journal = subprocess.check_output(['journalctl', '-u', unit.name, '--no-pager', '-n', '15'], text=True)
        (output / (label + '.journal')).write_text(journal)
        assert int(state['ExecMainStatus']) == expected, state
        if expected == 0:
            assert start.returncode == 0 and state['Result'] == 'success'
            assert (logs / 'battery.jsonl').read_text() == 'passive-logger-ok'
            assert logs.stat().st_mode & 0o777 == 0o700
            assert (logs / 'battery.jsonl').stat().st_mode & 0o777 == 0o600
        results.append({'case': label, 'state': state, 'directory_absent_before_start': True})
    finally:
        subprocess.run(['systemctl', 'stop', unit.name], check=False)
        unit.unlink()
        subprocess.run(['systemctl', 'daemon-reload'], check=True)
        subprocess.run(['systemctl', 'reset-failed', unit.name], capture_output=True)
        if logs.exists(): shutil.rmtree(logs)
(output / 'result.json').write_text(json.dumps({'passed':True,'cases':results,
    'scope':'Actual log-directory creation and stdout ordering; printf replaces the hardware sampler.'},indent=2)+'\n')
print(json.dumps(results), flush=True)

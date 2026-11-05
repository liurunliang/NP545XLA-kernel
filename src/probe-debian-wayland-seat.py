#!/usr/bin/env python3
"""One-shot physical eDP test. sudo ./probe-debian-wayland-seat.py [--check] /path/to/probe-debian-gpu"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def run(*argv, check=True):
    return subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          check=check, timeout=5).stdout.strip()


def props(verb, name, *fields):
    args = [f'--property={field}' for field in fields]
    return dict(line.split('=', 1) for line in run('loginctl', verb, name, *args).splitlines())


def active():
    return props('show-seat', 'seat0', 'ActiveSession')['ActiveSession']


def session(sid):
    return props('show-session', sid, 'Name', 'User', 'Class', 'Type', 'Active', 'Seat', 'Remote',
                 'VTNr', 'Leader', 'Service')


def sessions():
    return [line.split()[0] for line in run('loginctl', 'list-sessions', '--no-legend').splitlines()]


def current_sessions():
    for sid in sessions():
        try:
            yield sid, session(sid)
        except subprocess.CalledProcessError:
            continue  # An unrelated SSH session may have closed after enumeration.


def unit_value(unit, key):
    return run('systemctl', 'show', unit, '-p', key, '--value')


def has_device(tree, node):
    return any(parent.name == node for parent in tree.resolve().parents)


def used_vts():
    with open('/dev/tty0', 'rb', buffering=0) as console:
        state = fcntl.ioctl(console, 0x5603, bytes(6))  # VT_GETSTATE, struct vt_stat
    return struct.unpack('=HHH', state)[2]


def preflight(probe):
    dt = Path('/proc/device-tree/compatible')
    require(sys.platform == 'linux' and os.uname().machine == 'aarch64' and dt.is_file() and
            b'samsung,np545xla' in dt.read_bytes().split(b'\0') and
            (dt.parent / 'model').read_bytes().rstrip(b'\0') == b'Samsung Galaxy Book Go 5G',
            'Requires the Samsung NP545XLA device tree')
    require(os.geteuid() == 0 and probe.is_file() and os.access(probe, os.X_OK),
            'Run as root with the compiled, executable probe-debian-gpu')
    for name in ('cage', 'wayland-info', 'xrandr', 'runuser', 'systemd-run', 'loginctl'):
        require(shutil.which(name), f'Missing {name}')
    sid = active()
    s = session(sid)
    require(all(s[k] == v for k, v in dict(Name='liurunliang', Class='user', Type='x11', Seat='seat0',
                                           Active='yes', Remote='no', Service='lightdm').items()),
            f'Requires the active local LightDM X11 user session, found {s}')
    require(unit_value('lightdm.service', 'ActiveState') == 'active', 'LightDM is not active')
    xfce = run('pgrep', '-u', s['User'], '-x', 'xfce4-session').splitlines()
    require(len(xfce) == 1 and s['VTNr'].isdecimal() and int(s['VTNr']) > 0, 'Ambiguous Xfce session or VT')
    require(Path('/sys/class/tty/tty0/active').read_text().strip() == 'tty' + s['VTNr'], 'X11 VT is not in foreground')
    xorg = [pid for pid in run('pgrep', '-x', 'Xorg').splitlines()
            if ('vt' + s['VTNr']).encode() in Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')]
    require(len(xorg) == 1, 'Expected a single Xorg server on this VT')
    # Read only display connection parameters; never log the surrounding session environment.
    env = dict(entry.split(b'=', 1) for entry in Path(f'/proc/{xfce[0]}/environ').read_bytes().split(b'\0') if b'=' in entry)
    user = pwd.getpwnam(s['Name'])
    xenv = [f"DISPLAY={env[b'DISPLAY'].decode()}", 'XAUTHORITY=' + os.fsdecode(env.get(b'XAUTHORITY',
            os.fsencode(Path(user.pw_dir) / '.Xauthority')))]
    xcheck = ['runuser', '-u', user.pw_name, '--', 'env', *xenv, 'xrandr', '--current']
    require(re.search(r'^eDP[-\w]* connected', run(*xcheck), re.M), 'Current Xfce cannot query its connected eDP')
    drm = Path('/sys/class/drm')
    panels = [p for p in drm.glob('card*-eDP-*') if (p / 'status').read_text().strip() == 'connected']
    require(len(panels) == 1, 'Expected exactly one connected internal eDP')
    card, output = panels[0].name.split('-', 1)
    card_path = drm / card
    require(has_device(card_path, 'ae01000.display-controller'), 'Unexpected eDP controller')
    renders = [p for p in drm.glob('renderD*') if has_device(p, '2c00000.gpu') or
               (p / 'device').resolve() == (card_path / 'device').resolve()]
    require(len(renders) == 1, 'Expected one Adreno render node in split or unified mode')
    kms, render = [Path('/dev/dri') / n for n in (card, renders[0].name)]
    require(kms.is_char_device() and render.is_char_device(), 'Missing native DRM device')
    dbg = Path('/sys/kernel/debug/dri') / str(os.minor(kms.stat().st_rdev))
    require(all((dbg / name).is_file() for name in ('clients', 'state')), 'DRM debugfs clients/state are required for scanout evidence')
    allocated = {s['VTNr'] for _, s in current_sessions()}
    used = used_vts()
    for n in range(9, 16):
        tty = Path(f'/dev/tty{n}')
        if (not used & (1 << n) and str(n) not in allocated and tty.is_char_device() and
                unit_value(f'getty@tty{n}.service', 'ActiveState') == 'inactive'):
            return dict(old=sid, old_vt=s['VTNr'], old_leader=s['Leader'], xfce=xfce[0], xorg=xorg[0], xcheck=xcheck,
                        user=user.pw_name, vt=str(n), kms=str(kms), render=str(render), output=output, debug=str(dbg))
    raise RuntimeError('No free test VT between tty9 and tty15')


def client(probe, render, output):
    require(os.geteuid() != 0 and os.environ.get('XDG_SEAT') == 'seat0', 'Client needs the local user seat')
    os.environ.pop('DISPLAY', None)
    info = run('wayland-info')
    require(re.search(r"\bname:\s*['\"]?" + re.escape(output) + r"(?:['\"]|\s|$)", info, re.M),
            f'Compositor did not advertise {output}')
    print(f'Wayland output {output}, session {os.environ.get("XDG_SESSION_ID")}', flush=True)
    subprocess.run([probe, 'wayland', render], check=True, timeout=14)
    print('Physical Wayland client completed', flush=True)
    time.sleep(3)  # Keep Cage and its hardware state alive for the independent root-side sample.


def scanout(state, output):
    blocks = re.split(r'(?=^(?:plane|crtc|connector)\[)', state, flags=re.M)
    mapping = next((re.search(r'^\s*crtc=(\S+)', b, re.M) for b in blocks
                    if re.match(r'connector\[\d+\]: ' + re.escape(output) + r'$', b, re.M)), None)
    return bool(mapping and any(re.match(r'crtc\[\d+\]: ' + re.escape(mapping[1]) + r'$', b, re.M)
                                and re.search(r'^\s*active=1$', b, re.M) for b in blocks))


def kms_sample(work, cfg, pid):
    dbg = Path(cfg['debug'])
    clients, state = [(dbg / k).read_text() for k in ('clients', 'state')]
    ids, retained_render = set(), False
    for fd in Path(f'/proc/{pid}/fd').glob('*'):
        try:
            if fd.samefile(cfg['kms']):
                info = (fd.parent.parent / 'fdinfo' / fd.name).read_text()
                ids.update(re.findall(r'^drm-client-id:\s*(\d+)', info, re.M))
            elif fd.samefile(cfg['render']):
                retained_render = True
        except (OSError, UnicodeError):
            continue
    # logind can open the FD on behalf of Cage. Match the DRM file ID retained by Cage.
    master = any(len(row) >= 8 and row[3] == 'y' and row[-1] in ids for row in map(str.split, clients.splitlines()))
    if not (work / 'kms-initial-state.txt').exists():
        (work / 'kms-initial-state.txt').write_text(state)
        (work / 'kms-initial-clients.txt').write_text(clients)
    if master and retained_render and scanout(state, cfg['output']):
        (work / 'kms-clients.txt').write_text(clients)
        (work / 'kms-state.txt').write_text(state)
        (work / 'seat-evidence.txt').write_text(f"Cage PID {pid}; retained KMS client IDs {sorted(ids)}; {cfg['output']} active; render {cfg['render']}\n")
        return True
    return False


def restore(work, cfg):
    old = session(cfg['old'])
    require(old['Leader'] == cfg['old_leader'] and old['VTNr'] == cfg['old_vt'], 'Original session identity changed')
    def back_on_x11():
        return active() == cfg['old'] and Path('/sys/class/tty/tty0/active').read_text().strip() == 'tty' + cfg['old_vt']

    if not back_on_x11():
        run('loginctl', 'activate', cfg['old'], check=False)
        for _ in range(8):
            if back_on_x11():
                break
            time.sleep(.15)
        if not back_on_x11():
            run('systemctl', 'stop', '--no-block', work.name + '.service', check=False)
            with open('/dev/tty0', 'rb', buffering=0) as console:
                fcntl.ioctl(console, 0x5606, int(cfg['old_vt']))  # VT_ACTIVATE
    for _ in range(12):
        if back_on_x11():
            break
        time.sleep(.15)
    else:
        raise RuntimeError('Could not return to the original X11 session and VT')
    run('systemctl', 'stop', '--no-block', work.name + '.service', check=False)
    # A PAM session scope can outlive the transient service's main process.
    record = work / 'test-session.txt'
    if record.exists():
        sid, pid = record.read_text().split()
        if sid != cfg['old'] and sid in sessions():
            test = session(sid)
            if (test['Leader'] == pid and test['Name'] == cfg['user'] and test['Seat'] == 'seat0' and
                    test['VTNr'] == cfg['vt'] and test['Type'] == 'wayland'):
                run('loginctl', 'terminate-session', sid, check=False)


def physical(work, cfg, probe):
    tool = work / 'seat.py'
    shutil.copyfile(__file__, tool)
    shutil.copyfile(probe, work / 'probe-debian-gpu')
    for exe in (tool, work / 'probe-debian-gpu'):
        exe.chmod(0o755)
    unit, guard = work.name + '.service', work.name + '-restore'
    (work / 'config.json').write_text(json.dumps(cfg))
    run('systemd-run', '--quiet', f'--unit={guard}', '--on-active=40s', '--timer-property=AccuracySec=1s',
        '/usr/bin/python3', tool, '--restore')
    require(unit_value(guard + '.timer', 'ActiveState') == 'active', 'Recovery timer did not arm')
    try:
        require(active() == cfg['old'] and not used_vts() & (1 << int(cfg['vt'])), 'Seat or vacant VT changed during preflight')
        # Use a new PAM/logind session attached to this VT, independent of the SSH controller.
        cmd = ['systemd-run', '--quiet', '--no-block', f'--unit={unit}', '-p', 'PAMName=login',
               '-p', f"User={cfg['user']}", '-p', f"TTYPath=/dev/tty{cfg['vt']}", '-p', 'StandardInput=tty-fail',
               '-p', f'StandardOutput=append:{work}/cage.log', '-p', 'StandardError=inherit',
               '-p', 'RuntimeMaxSec=32s', '-p', 'TimeoutStopSec=3s', '-p', 'RemainAfterExit=yes']
        settings = dict(XDG_SESSION_TYPE='wayland', XDG_SEAT='seat0', XDG_VTNR=cfg['vt'], LIBSEAT_BACKEND='logind',
                        WLR_BACKENDS='drm,libinput', WLR_DRM_DEVICES=cfg['kms'], WLR_RENDER_DRM_DEVICE=cfg['render'], WLR_RENDERER='gles2')
        cmd.extend(f'--setenv={k}={v}' for k, v in settings.items())
        run(*cmd, '/usr/bin/env', '-u', 'DISPLAY', '-u', 'WAYLAND_DISPLAY', '-u', 'LIBGL_ALWAYS_SOFTWARE',
            '-u', 'GALLIUM_DRIVER', '/usr/bin/cage', '-s', '--', tool, '--client', work / 'probe-debian-gpu', cfg['render'], cfg['output'])
        started = time.monotonic()
        deadline = started + 25
        sid, sampled = None, False
        while time.monotonic() < deadline:
            sub = unit_value(unit, 'SubState')
            if sub in ('failed', 'exited') or (sub == 'dead' and time.monotonic() - started > 2):
                break
            pid = unit_value(unit, 'MainPID')
            if pid != '0' and not sid:
                for i, s in current_sessions():
                    if (s['Leader'] == pid and s['Seat'] == 'seat0' and s['VTNr'] == cfg['vt'] and
                            s['Name'] == cfg['user'] and s['Type'] == 'wayland' and s['Remote'] == 'no'):
                        sid = i
                        (work / 'test-session.txt').write_text(f'{sid} {pid}\n')
                        run('loginctl', 'activate', sid)
                        break
            if sid and active() == sid and not sampled and Path(f'/proc/{pid}/comm').is_file():
                if Path(f'/proc/{pid}/comm').read_text().strip() == 'cage':
                    sampled = kms_sample(work, cfg, pid)
                    if sampled:
                        (work / 'logind-seat.json').write_text(json.dumps(session(sid), indent=2) + '\n')
            time.sleep(.15)
        log = (work / 'cage.log').read_text(errors='replace')
        print(log, flush=True)
        require(sid and sampled and 'Physical Wayland client completed' in log and
                unit_value(unit, 'SubState') == 'exited' and unit_value(unit, 'ExecMainStatus') == '0',
                'Physical frame, DRM-master, eDP scanout or clean client exit was not verified')
    finally:
        restore(work, cfg)
        require(Path(f"/proc/{cfg['xfce']}/comm").read_text().strip() == 'xfce4-session' and
                Path(f"/proc/{cfg['xorg']}/comm").read_text().strip() == 'Xorg' and
                unit_value('lightdm.service', 'ActiveState') == 'active', 'Original LightDM/Xorg/Xfce did not survive')
        for _ in range(5):
            if re.search(r'^eDP[-\w]* connected', run(*cfg['xcheck'], check=False), re.M):
                break
            time.sleep(.3)
        else:
            raise RuntimeError('Original Xfce could not query its eDP after returning')
        run('systemctl', 'stop', guard + '.timer')
        print(f"Returned to LightDM/Xfce session {cfg['old']} on VT {cfg['old_vt']}", flush=True)


def main():
    if sys.argv[1:2] == ['--client']:
        client(*sys.argv[2:])
        return
    if sys.argv[1:] == ['--restore']:
        work = Path(__file__).resolve().parent
        require(os.geteuid() == 0 and work.parent == Path('/run') and work.stat().st_uid == 0 and
                work.stat().st_mode & 0o022 == 0, 'Recovery must use the root-owned runtime copy')
        restore(work, json.loads((work / 'config.json').read_text()))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='read-only preflight, no VT switch')
    parser.add_argument('probe', type=Path)
    args = parser.parse_args()
    cfg = preflight(args.probe)
    print(f"Display {cfg['output']} on {cfg['kms']}, render {cfg['render']}, current VT {cfg['old_vt']}, test VT {cfg['vt']}", flush=True)
    if args.check:
        return
    with open('/run/np545xla-wayland-seat.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require(not run('systemctl', 'list-units', '--no-legend', '--type=timer', '--state=active', 'np545xla-seat-*-restore.timer'),
                'A previous seat test still has its recovery timer armed')
        work = Path(tempfile.mkdtemp(prefix='np545xla-seat-', dir='/run'))
        work.chmod(0o755)
        print(f'Evidence: {work}', flush=True)
        physical(work, cfg, args.probe)
    print('PASS: native Wayland hardware render and physical eDP scanout; Xfce restored')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        sys.exit(f'FAIL: {exc}')

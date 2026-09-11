#!/usr/bin/env python3
"""Run the real idle delegate through lock cycles in a disposable nested Hyprland.

Requires Hyprland and quickshell on PATH and a running Wayland compositor.
Override their executable paths with HYPRLAND and QUICKSHELL. Only the nested
session is locked. Idle and return actions are replaced with counters.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    source = (Path(__file__).resolve().parent.parent / 'modules/IdleMonitors.qml').read_text()
    delegate = source[source.index('        IdleMonitor {'):source.rfind('\n    }')]
    delegate = delegate.replace(
        'required property var modelData',
        'property var modelData: ({ onlyWhenLocked: true, timeout: 0.1, '
        'idleAction: "off", returnAction: "on" })',
    )
    qml = '''import QtQuick
import Quickshell
import Quickshell.Wayland
Scope {
    id: root
    property var lock: wrapper
    property bool enabled: true
    property bool hasPlayer: false
    property bool isCharging: false
    property int actions: 0
    property int returns: 0
    property int failures: 0
    property int step: 0
    QtObject { id: wrapper; property var lock: sessionLock }
    WlSessionLock {
        id: sessionLock
        WlSessionLockSurface { color: "black" }
    }
    function handleIdleAction(action) {
        if (action === "off") actions++;
        if (action === "on") returns++;
    }
    function check(condition, message) {
        if (!condition) {
            failures++;
            console.error("FAIL", message);
        }
    }
''' + delegate + '''
    Timer {
        interval: 500
        running: true
        repeat: true
        onTriggered: {
            const cycle = Math.floor(root.step / 6);
            switch (root.step % 6) {
            case 0:
                root.check(!idleMonitor.enabled, "lock-only monitor enabled before locking");
                sessionLock.locked = true;
                break;
            case 1:
                root.check(sessionLock.secure, "nested session never secured");
                root.check(root.actions === cycle + 1, "idle action must run while locked");
                sessionLock.locked = false;
                break;
            case 2:
                root.check(!sessionLock.locked, "nested session did not unlock");
                root.check(!idleMonitor.enabled, "monitor remains enabled after unlock");
                root.check(root.returns === cycle + 1, "unlock must run return action once");
                // Reset the idle notification, then let it expire while unlocked.
                idleMonitor.timeout = 10;
                break;
            case 3:
                idleMonitor.timeout = 0.1;
                break;
            case 5:
                root.check(root.actions === cycle + 1, "idle action ran while unlocked");
                root.check(root.returns === cycle + 1, "unexpected return action count while unlocked");
                if (cycle === 2) {
                    console.log(root.failures === 0 ? "PASS idle lock cycles" : "FAIL idle lock cycles");
                    Qt.quit();
                }
            }
            root.step++;
        }
    }
}
'''
    with tempfile.TemporaryDirectory(prefix='idle-lock-test-') as directory:
        work = Path(directory)
        env = dict(os.environ)
        env['WAYLAND_DISPLAY'] = str(Path(env['XDG_RUNTIME_DIR']) / env['WAYLAND_DISPLAY'])
        env['XDG_RUNTIME_DIR'] = directory
        env['AQ_DRM_DEVICES'] = '/dev/null'
        (work / 'hyprland.conf').write_text(
            'monitor = , 800x600@60, auto, 1\n'
            'misc {\n disable_hyprland_logo = true\n disable_splash_rendering = true\n}\n'
        )
        (work / 'shell.qml').write_text(qml)
        with (work / 'compositor.log').open('w') as log:
            compositor = subprocess.Popen(
                [env.get('HYPRLAND', 'Hyprland'), '--config', str(work / 'hyprland.conf')],
                env=env, stdout=log, stderr=log,
            )
            try:
                for _ in range(100):
                    sockets = [path for path in work.glob('wayland-*') if path.is_socket()]
                    if sockets:
                        env['WAYLAND_DISPLAY'] = sockets[0].name
                        break
                    if compositor.poll() is not None:
                        break
                    time.sleep(0.05)
                else:
                    sockets = []
                if not sockets:
                    raise RuntimeError((work / 'compositor.log').read_text())
                result = subprocess.run(
                    [env.get('QUICKSHELL', 'quickshell'), '-p', str(work / 'shell.qml')],
                    env=env, capture_output=True, text=True, timeout=20,
                )
                output = result.stdout + result.stderr
                print(output)
                if result.returncode or 'PASS idle lock cycles' not in output or 'FAIL' in output:
                    raise SystemExit(1)
            finally:
                compositor.terminate()
                try:
                    compositor.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    compositor.kill()
                    compositor.wait()


if __name__ == '__main__':
    main()

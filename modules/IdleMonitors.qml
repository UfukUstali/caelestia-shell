pragma ComponentBehavior: Bound

import "lock"
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.UPower
import Caelestia.Config
import Caelestia.Services
import qs.services

Scope {
    id: root

    required property Lock lock
    readonly property bool hasPlayer: Players.list.some(p => p.isPlaying)
    readonly property bool isCharging: !UPower.onBattery
    readonly property bool enabled: {
        if (GlobalConfig.general.idle.inhibitWhenAudio && hasPlayer)
            return false;
        if (GlobalConfig.general.idle.inhibitWhenCharging && isCharging)
            return false;
        return true;
    }

    function handleIdleAction(action: var): void {
        if (!action)
            return;

        if (action === "lock")
            lock.lock.locked = true;
        else if (action === "unlock")
            lock.lock.locked = false;
        else if (typeof action === "string")
            Hypr.dispatch(Hypr.usingLua && ["dpms off", "dpms on"].includes(action) ? `hl.dsp.dpms({ action = "${action === "dpms off" ? "disable" : "enable"}" })` : action);
        else if (!SessionManager.exec(action))
            Quickshell.execDetached(action);
    }

    Connections {
        function onAboutToSleep(): void {
            if (GlobalConfig.general.idle.lockBeforeSleep)
                root.lock.lock.locked = true;
        }

        function onLockRequested(): void {
            root.lock.lock.locked = true;
        }

        function onUnlockRequested(): void {
            root.lock.lock.unlock();
        }

        target: SessionManager
    }

    Variants {
        model: GlobalConfig.general.idle.timeouts

        IdleMonitor {
            id: idleMonitor

            required property var modelData
            property bool actionRan: false

            function returnFromIdle(): void {
                if (!actionRan)
                    return;
                actionRan = false;
                root.handleIdleAction(modelData.returnAction);
            }

            function updateIdle(): void {
                if (isIdle && enabled) {
                    actionRan = true;
                    root.handleIdleAction(modelData.idleAction);
                } else {
                    returnFromIdle();
                }
            }

            enabled: {
                // Enabling creates a fresh Wayland idle notification, so this
                // timeout starts once the compositor confirms the lock.
                // Use secure because locked can miss its unlock notification.
                if (modelData.onlyWhenLocked && !root.lock.lock.secure)
                    return false;
                if (!root.enabled || !(modelData.enabled ?? true))
                    return false;
                if (modelData.inhibitWhenAudio && root.hasPlayer)
                    return false;
                if (modelData.inhibitWhenCharging && root.isCharging)
                    return false;
                return true;
            }
            timeout: modelData.timeout
            respectInhibitors: modelData.respectInhibitors ?? true
            onIsIdleChanged: updateIdle()
            onEnabledChanged: {
                if (!enabled)
                    returnFromIdle();
            }
        }
    }
}

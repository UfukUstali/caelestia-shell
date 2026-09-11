pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.components.misc

Singleton {
    id: root

    property list<var> ddcMonitors: []
    readonly property var ddcMonitorMap: {
        const map = {};
        for (const m of ddcMonitors)
            map[m.connector] = m;
        return map;
    }
    readonly property list<Monitor> monitors: variants.instances // qmllint disable incompatible-type
    property bool appleDisplayPresent: false
    property real brightness: 0
    property bool brightnessInitialized: false
    property bool brightnessRequested: false

    function applyGlobalBrightness(value: real): void {
        if (!isFinite(value))
            return;
        brightness = Math.max(0, Math.min(1, value));
        brightnessInitialized = true;
        brightnessRequested = true;
        for (const monitor of monitors)
            monitor.setBrightness(brightness);
    }

    function seedBrightness(value: real): void {
        // Read the first available display without changing hardware at startup.
        if (!brightnessInitialized && isFinite(value)) {
            brightness = value;
            brightnessInitialized = true;
        }
    }

    function parseDdcMonitors(output: string): var {
        const found = [];
        for (const block of output.trim().split(/\n\s*\n/)) {
            // ddcutil also reports invalid displays, including laptop panels.
            if (!block.startsWith("Display "))
                continue;
            const bus = block.match(/I2C bus:\s*\/dev\/i2c-([0-9]+)/);
            const connector = block.match(/DRM connector:\s*(.+)/);
            if (bus && connector)
                found.push({
                    busNum: bus[1],
                    connector: connector[1].trim().replace(/^card\d+-/, "")
                });
        }
        return found;
    }

    function getMonitorForScreen(screen: ShellScreen): var {
        return monitors.find(m => m.modelData === screen); // qmllint disable missing-property
    }

    function getMonitor(query: string): var {
        if (query === "active") {
            return monitors.find(m => Hypr.monitorFor(m.modelData)?.focused); // qmllint disable missing-property
        }

        if (query.startsWith("model:")) {
            const model = query.slice(6);
            return monitors.find(m => m.modelData.model === model); // qmllint disable missing-property
        }

        if (query.startsWith("serial:")) {
            const serial = query.slice(7);
            return monitors.find(m => m.modelData.serialNumber === serial); // qmllint disable missing-property
        }

        if (query.startsWith("id:")) {
            const id = parseInt(query.slice(3), 10);
            return monitors.find(m => Hypr.monitorFor(m.modelData)?.id === id); // qmllint disable missing-property
        }

        return monitors.find(m => m.modelData.name === query); // qmllint disable missing-property
    }

    function increaseBrightness(): void {
        applyGlobalBrightness(brightness + GlobalConfig.services.brightnessIncrement);
    }

    function decreaseBrightness(): void {
        applyGlobalBrightness(brightness - GlobalConfig.services.brightnessIncrement);
    }

    onMonitorsChanged: {
        ddcMonitors = [];
        ddcProc.running = true;
    }

    Variants {
        id: variants

        model: Quickshell.screens // Don't respect excluded screens cause ipc

        Monitor {}
    }

    Process {
        running: true
        command: ["sh", "-c", "asdbctl get"] // To avoid warnings if asdbctl is not installed
        stdout: StdioCollector {
            onStreamFinished: root.appleDisplayPresent = text.trim().length > 0
        }
    }

    Process {
        id: ddcProc

        command: ["ddcutil", "detect", "--brief"]
        stdout: StdioCollector {
            onStreamFinished: root.ddcMonitors = root.parseDdcMonitors(text)
        }
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "brightnessUp"
        description: "Increase brightness"
        onPressed: root.increaseBrightness()
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "brightnessDown"
        description: "Decrease brightness"
        onPressed: root.decreaseBrightness()
    }

    IpcHandler {
        function get(): real {
            return root.brightness;
        }

        // Allows searching by active/model/serial/id/name
        function getFor(query: string): real {
            return root.getMonitor(query)?.uiBrightness ?? -1;
        }

        function set(value: string): string {
            return setFor("all", value);
        }

        // Handles brightness value like brightnessctl: 0.1, +0.1, 0.1-, 10%, +10%, 10%-
        function setFor(query: string, value: string): string {
            const all = query === "all";
            const monitor = all ? null : root.getMonitor(query);
            if (!all && !monitor)
                return "Invalid monitor: " + query;

            const current = all ? root.brightness : monitor.uiBrightness;
            let targetBrightness;
            if (value.endsWith("%-")) {
                const percent = parseFloat(value.slice(0, -2));
                targetBrightness = current - (percent / 100);
            } else if (value.startsWith("+") && value.endsWith("%")) {
                const percent = parseFloat(value.slice(1, -1));
                targetBrightness = current + (percent / 100);
            } else if (value.endsWith("%")) {
                const percent = parseFloat(value.slice(0, -1));
                targetBrightness = percent / 100;
            } else if (value.startsWith("+")) {
                const increment = parseFloat(value.slice(1));
                targetBrightness = current + increment;
            } else if (value.endsWith("-")) {
                const decrement = parseFloat(value.slice(0, -1));
                targetBrightness = current - decrement;
            } else if (value.includes("%") || value.includes("-") || value.includes("+")) {
                return `Invalid brightness format: ${value}\nExpected: 0.1, +0.1, 0.1-, 10%, +10%, 10%-`;
            } else {
                targetBrightness = parseFloat(value);
            }

            if (!isFinite(targetBrightness))
                return `Failed to parse value: ${value}\nExpected: 0.1, +0.1, 0.1-, 10%, +10%, 10%-`;

            if (all) {
                root.applyGlobalBrightness(targetBrightness);
                return `Set all monitors brightness to ${+root.brightness.toFixed(2)}`;
            }
            monitor.setBrightness(targetBrightness);
            return `Set monitor ${monitor.modelData.name} brightness to ${+monitor.uiBrightness.toFixed(2)}`;
        }

        target: "brightness"
    }

    component Monitor: QtObject {
        id: monitor

        required property ShellScreen modelData
        readonly property var ddcInfo: root.ddcMonitorMap[modelData.name] ?? null
        readonly property bool isDdc: ddcInfo !== null
        readonly property string busNum: ddcInfo?.busNum ?? ""
        readonly property bool isAppleDisplay: root.appleDisplayPresent && modelData.model.startsWith("StudioDisplay")
        // Only built-in panels may use the system backlight. An undetected
        // external monitor must never write to the laptop's backlight.
        readonly property bool isBacklight: /^(eDP|LVDS|DSI)-/.test(modelData.name)
        readonly property string backend: isAppleDisplay ? "apple" : isDdc ? "ddc:" + busNum : isBacklight ? "backlight" : ""
        readonly property var screenConfig: GlobalConfig.forScreen(modelData.name)
        readonly property real minBrightness: Math.max(0, Math.min(1, screenConfig.services.minBrightness))
        readonly property real maxBrightness: Math.max(minBrightness, Math.min(1, screenConfig.services.maxBrightness))
        property real uiBrightness: 0
        property real brightness: NaN
        property bool requested: false
        property bool pending: false

        readonly property Process initProc: Process {
            stdout: StdioCollector {
                onStreamFinished: {
                    if (monitor.isAppleDisplay) {
                        monitor.acceptInitialBrightness(parseInt(text.trim()) / 101);
                    } else {
                        const [, , , cur, max] = text.trim().split(/\s+/);
                        monitor.acceptInitialBrightness(parseInt(cur) / parseInt(max));
                    }
                }
            }
            onExited: () => Qt.callLater(monitor.flushBrightness)
            // qmllint disable signal-handler-parameters
        }

        readonly property Process writeProc: Process {
            onExited: code => { // qmllint disable signal-handler-parameters
                if (code !== 0) {
                    monitor.brightness = NaN;
                    console.warn("Failed to set brightness for", monitor.modelData.name, code);
                }
                if (monitor.isDdc)
                    monitor.timer.restart();
                else
                    Qt.callLater(monitor.flushBrightness);
            }
        }

        readonly property Timer timer: Timer {
            interval: 500
            onTriggered: monitor.flushBrightness()
        }

        function acceptInitialBrightness(value: real): void {
            if (!isFinite(value) || requested)
                return;
            brightness = Math.max(0, Math.min(1, value));
            const span = maxBrightness - minBrightness;
            uiBrightness = span > 0 ? Math.max(0, Math.min(1, (brightness - minBrightness) / span)) : 0;
            root.seedBrightness(uiBrightness);
        }

        function setBrightness(value: real): void {
            if (!isFinite(value))
                return;
            // Keep the latest logical request, even if hardware rounds it away
            // or an earlier DDC write is still running.
            uiBrightness = Math.max(0, Math.min(1, value));
            requested = true;
            pending = true;
            flushBrightness();
        }

        function flushBrightness(): void {
            if (!pending || !backend || initProc.running || writeProc.running || timer.running)
                return;
            const mapped = minBrightness + (maxBrightness - minBrightness) * uiBrightness;
            const rounded = Math.round(mapped * 100);
            pending = false;
            if (Math.round(brightness * 100) === rounded)
                return;
            brightness = rounded / 100;
            if (isAppleDisplay)
                writeProc.command = ["asdbctl", "set", rounded];
            else if (isDdc)
                writeProc.command = ["ddcutil", "-b", busNum, "setvcp", "10", rounded];
            else
                writeProc.command = ["brightnessctl", "-c", "backlight", "s", `${rounded}%`];
            writeProc.running = true;
        }

        function initBrightness(): void {
            if (!backend || initProc.running || writeProc.running)
                return;
            brightness = NaN;
            if (root.brightnessRequested) {
                setBrightness(root.brightness);
                return;
            }
            if (isAppleDisplay)
                initProc.command = ["asdbctl", "get"];
            else if (isDdc)
                initProc.command = ["ddcutil", "-b", busNum, "getvcp", "10", "--brief"];
            else
                initProc.command = ["sh", "-c", "echo a b c $(brightnessctl -c backlight g) $(brightnessctl -c backlight m)"];
            initProc.running = true;
        }

        function updateBounds(): void {
            if (requested)
                setBrightness(uiBrightness);
            else
                acceptInitialBrightness(brightness);
        }

        onMinBrightnessChanged: updateBounds()
        onMaxBrightnessChanged: updateBounds()
        onBackendChanged: Qt.callLater(initBrightness)
        Component.onCompleted: Qt.callLater(initBrightness)
    }
}

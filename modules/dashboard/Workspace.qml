pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.services

// Adapted from impasto's OverviewPanel.qml by andreumassanet, GPL-3.0.
// https://github.com/andreumassanet/impasto
Item {
    id: root

    required property ScreenState screenState
    required property bool paneActive

    readonly property bool observing: paneActive && screenState.dashboard
    property int selectedId: 1
    property var clients: []
    property var monitorData: []
    readonly property var workspaceIds: {
        const ids = new Set(Array.from({
            length: Math.max(10, Config.bar.workspaces.shown)
        }, (_, i) => i + 1));
        for (const workspace of Hypr.workspaces.values)
            if (workspace.id > 0)
                ids.add(workspace.id);
        for (const client of clients)
            ids.add(client.workspace.id);
        return [...ids].sort((a, b) => a - b);
    }
    readonly property int columns: Math.min(5, workspaceIds.length)
    readonly property int rows: Math.ceil(workspaceIds.length / columns)
    readonly property int gap: Tokens.spacing.small
    readonly property real aspect: 0.625

    function refresh(): void {
        if (!clientsProcess.running)
            clientsProcess.running = true;
        if (!monitorsProcess.running)
            monitorsProcess.running = true;
    }

    function focusWorkspace(id: int): void {
        Hypr.dispatch(Hypr.usingLua ? `hl.dsp.focus({ workspace = ${id} })` : `workspace ${id}`);
        screenState.dashboard = false;
    }

    function windowAction(action: string, address: string): void {
        const lua = {
            focus: "focus",
            close: "window.close",
            float: "window.float"
        };
        const legacy = {
            focus: "focuswindow",
            close: "closewindow",
            float: "togglefloating"
        };
        Hypr.dispatch(Hypr.usingLua ? `hl.dsp.${lua[action]}({ window = "address:${address}" })` : `${legacy[action]} address:${address}`);
    }

    function moveClient(address: string, workspaceId: int): void {
        Hypr.dispatch(Hypr.usingLua ? `hl.dsp.window.move({ workspace = ${workspaceId}, window = "address:${address}", follow = false })` : `movetoworkspacesilent ${workspaceId},address:${address}`);
    }

    function toplevelFor(client: var): var {
        const native = Hypr.toplevels.values.find(entry => entry.address === client.address || `0x${entry.address}` === client.address);
        if (native?.wayland)
            return native.wayland;
        const entries = ToplevelManager.toplevels.values;
        return entries.find(entry => entry.appId === client.class && entry.title === client.title) ?? entries.find(entry => entry.title === client.title) ?? null;
    }

    function selectBy(delta: int): void {
        const count = root.workspaceIds.length;
        const index = root.workspaceIds.indexOf(root.selectedId);
        root.selectedId = root.workspaceIds[(index + delta + count) % count];
    }

    function activate(): void {
        root.focusWorkspace(root.selectedId);
    }

    Keys.onLeftPressed: root.selectBy(-1)
    Keys.onRightPressed: root.selectBy(1)
    Keys.onUpPressed: root.selectBy(-root.columns)
    Keys.onDownPressed: root.selectBy(root.columns)
    Keys.onReturnPressed: root.activate()
    Keys.onEnterPressed: root.activate()

    implicitWidth: 840
    implicitHeight: 360

    onObservingChanged: {
        screenState.workspaceKeyboardFocus = observing;
        if (observing) {
            refresh();
            selectedId = Hypr.activeWsId > 0 ? Hypr.activeWsId : workspaceIds[0];
            forceActiveFocus();
        }
    }
    Component.onCompleted: {
        screenState.workspaceKeyboardFocus = observing;
        if (observing) {
            refresh();
            selectedId = Hypr.activeWsId > 0 ? Hypr.activeWsId : workspaceIds[0];
            forceActiveFocus();
        }
    }
    Component.onDestruction: screenState.workspaceKeyboardFocus = false
    Keys.onEscapePressed: screenState.dashboard = false

    Timer {
        interval: 500
        repeat: true
        running: root.observing
        onTriggered: root.refresh()
    }

    Process {
        id: clientsProcess

        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(text);
                    if (Array.isArray(data)) {
                        const clients = data.filter(c => c.mapped && !c.hidden && c.workspace?.id > 0);
                        if (!ghost.client && JSON.stringify(clients) !== JSON.stringify(root.clients))
                            root.clients = clients;
                    }
                } catch (error) {
                    console.warn("Workspace clients:", error);
                }
            }
        }
    }

    Process {
        id: monitorsProcess

        command: ["hyprctl", "monitors", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(text);
                    if (Array.isArray(data) && JSON.stringify(data) !== JSON.stringify(root.monitorData))
                        root.monitorData = data;
                } catch (error) {
                    console.warn("Workspace monitors:", error);
                }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: root.gap

        Item {
            id: board

            readonly property real inset: 3

            readonly property real cellWidth: Math.min((width - (root.columns - 1) * root.gap) / root.columns, ((height - (root.rows - 1) * root.gap) / root.rows - 2 * board.inset) / root.aspect + 2 * board.inset)
            readonly property real cellHeight: (board.cellWidth - 2 * board.inset) * root.aspect + 2 * board.inset

            property bool settled: false

            Layout.fillWidth: true
            Layout.fillHeight: true

            onCellWidthChanged: {
                board.settled = false;
                settle.restart();
            }

            Timer {
                id: settle

                interval: 120
                running: true
                onTriggered: board.settled = true
            }

            GridLayout {
                anchors.centerIn: parent
                columns: root.columns
                rowSpacing: root.gap
                columnSpacing: root.gap

                Repeater {
                    model: root.workspaceIds

                    Item {
                        id: cell

                        required property int modelData

                        readonly property int workspaceId: modelData
                        readonly property bool focused: Hypr.activeWsId === cell.workspaceId
                        readonly property bool selected: root.selectedId === cell.workspaceId
                        readonly property var windows: root.clients.filter(client => client.workspace.id === cell.workspaceId)
                        readonly property var workspace: Hypr.workspaces.values.find(w => w.id === workspaceId)
                        readonly property var monitor: root.monitorData.find(m => m.name === workspace?.monitor?.name) ?? root.monitorData.find(m => m.id === windows[0]?.monitor) ?? root.monitorData.find(m => m.name === root.screenState.modelData.name) ?? root.monitorData[0] ?? null
                        readonly property var reserved: monitor?.reserved ?? [0, 0, 0, 0]
                        readonly property bool rotated: monitor ? monitor.transform % 2 === 1 : false
                        readonly property real areaWidth: Math.max(1, (rotated ? monitor.height : monitor?.width ?? 1920) / (monitor?.scale ?? 1) - reserved[0] - reserved[2])
                        readonly property real areaHeight: Math.max(1, (rotated ? monitor.width : monitor?.height ?? 1200) / (monitor?.scale ?? 1) - reserved[1] - reserved[3])
                        readonly property real areaX: (monitor?.x ?? 0) + reserved[0]
                        readonly property real areaY: (monitor?.y ?? 0) + reserved[1]
                        readonly property real factor: Math.min((width - 2 * board.inset) / areaWidth, (height - 2 * board.inset) / areaHeight)
                        readonly property real insetX: (width - areaWidth * factor) / 2
                        readonly property real insetY: (height - areaHeight * factor) / 2
                        readonly property bool lit: cellHover.containsMouse || dropTarget.containsDrag
                        readonly property bool empty: cell.windows.length === 0

                        function windowAt(screenX: real, screenY: real, exclude: string): var {
                            const stack = cell.windows.slice().sort((a, b) => (a.floating ? 1 : 0) - (b.floating ? 1 : 0));
                            for (let i = stack.length - 1; i >= 0; i--) {
                                const client = stack[i];
                                if (client.address === exclude)
                                    continue;
                                if (screenX >= client.at[0] && screenX <= client.at[0] + client.size[0] && screenY >= client.at[1] && screenY <= client.at[1] + client.size[1])
                                    return client;
                            }
                            return null;
                        }

                        Layout.preferredWidth: board.cellWidth
                        Layout.preferredHeight: board.cellHeight

                        ClippingRectangle {
                            id: picture

                            anchors.fill: parent
                            contentUnderBorder: true
                            radius: Tokens.rounding.large
                            color: Colours.palette.m3surfaceContainer
                            border.width: cell.selected || dropTarget.containsDrag ? 2 : 1
                            border.color: cell.selected || cell.focused || dropTarget.containsDrag ? Colours.palette.m3primary : Colours.palette.m3outlineVariant

                            Behavior on border.color {
                                ColorAnimation {
                                    duration: 150
                                }
                            }

                            Image {
                                anchors.fill: parent
                                source: Wallpapers.current !== "" ? `file://${Wallpapers.current}` : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                sourceSize.width: 480
                                opacity: cell.empty ? 0.62 : 0.3

                                Behavior on opacity {
                                    NumberAnimation {
                                        duration: 150
                                    }
                                }
                            }

                            Repeater {
                                model: cell.windows

                                Item {
                                    id: thumb

                                    required property var modelData

                                    readonly property real gapL: thumb.x - board.inset

                                    readonly property real gapT: thumb.y - board.inset

                                    readonly property real gapR: cell.width - board.inset - (thumb.x + thumb.width)

                                    readonly property real gapB: cell.height - board.inset - (thumb.y + thumb.height)

                                    function corner(a: real, b: real): real {
                                        return Math.max(Tokens.rounding.small, Tokens.rounding.large - Math.max(a, b));
                                    }

                                    z: thumb.modelData.floating ? 2 : 1
                                    x: cell.insetX + (thumb.modelData.at[0] - cell.areaX) * cell.factor
                                    y: cell.insetY + (thumb.modelData.at[1] - cell.areaY) * cell.factor
                                    width: Math.max(8, thumb.modelData.size[0] * cell.factor)
                                    height: Math.max(8, thumb.modelData.size[1] * cell.factor)

                                    Behavior on x {
                                        enabled: board.settled

                                        NumberAnimation {
                                            duration: 250
                                            easing.type: Easing.OutCubic
                                        }
                                    }
                                    Behavior on y {
                                        enabled: board.settled

                                        NumberAnimation {
                                            duration: 250
                                            easing.type: Easing.OutCubic
                                        }
                                    }
                                    Behavior on width {
                                        enabled: board.settled

                                        NumberAnimation {
                                            duration: 250
                                            easing.type: Easing.OutCubic
                                        }
                                    }
                                    Behavior on height {
                                        enabled: board.settled

                                        NumberAnimation {
                                            duration: 250
                                            easing.type: Easing.OutCubic
                                        }
                                    }

                                    ClippingRectangle {
                                        id: frame

                                        anchors.fill: parent
                                        topLeftRadius: thumb.corner(thumb.gapL, thumb.gapT)
                                        topRightRadius: thumb.corner(thumb.gapR, thumb.gapT)
                                        bottomLeftRadius: thumb.corner(thumb.gapL, thumb.gapB)
                                        bottomRightRadius: thumb.corner(thumb.gapR, thumb.gapB)
                                        color: Colours.palette.m3surfaceContainer
                                        border.width: 2
                                        border.color: windowHover.containsMouse ? Colours.palette.m3secondary : Colours.palette.m3outlineVariant

                                        Behavior on border.color {
                                            ColorAnimation {
                                                duration: 150
                                            }
                                        }

                                        ScreencopyView {
                                            anchors.fill: parent
                                            captureSource: root.toplevelFor(thumb.modelData)
                                            live: root.observing
                                            paintCursor: false
                                            constraintSize: Qt.size(Math.max(1, Math.round(frame.width)), Math.max(1, Math.round(frame.height)))
                                        }

                                        Image {
                                            anchors.centerIn: parent
                                            width: Math.min(26, parent.width * 0.5)
                                            height: width
                                            visible: root.toplevelFor(thumb.modelData) === null
                                            source: Quickshell.iconPath(thumb.modelData.class, true)
                                            sourceSize.width: 52
                                            sourceSize.height: 52
                                        }
                                    }

                                    MouseArea {
                                        id: windowHover

                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

                                        preventStealing: true
                                        drag.target: pressedButtons & Qt.LeftButton ? ghost : null
                                        drag.threshold: 6

                                        onPressed: mouse => {
                                            if (mouse.button !== Qt.LeftButton)
                                                return;
                                            const at = thumb.mapToItem(board, 0, 0);
                                            ghost.client = thumb.modelData;
                                            ghost.x = at.x;
                                            ghost.y = at.y;
                                            ghost.width = thumb.width;
                                            ghost.height = thumb.height;
                                        }

                                        onPositionChanged: {
                                            if (drag.active) {
                                                ghost.dragging = true;
                                                return;
                                            }
                                            if (board.settled)
                                                root.selectedId = cell.workspaceId;
                                        }

                                        onCanceled: {
                                            ghost.dragging = false;
                                            ghost.client = null;
                                        }

                                        onReleased: {
                                            if (drag.active)
                                                ghost.Drag.drop();
                                            ghost.dragging = false;
                                            ghost.client = null;
                                        }

                                        onClicked: mouse => {
                                            if (mouse.button === Qt.RightButton) {
                                                root.windowAction("close", thumb.modelData.address);
                                                return;
                                            }
                                            if (mouse.button === Qt.MiddleButton) {
                                                root.windowAction("float", thumb.modelData.address);
                                                return;
                                            }
                                            root.windowAction("focus", thumb.modelData.address);
                                            root.screenState.dashboard = false;
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            text: cell.workspaceId
                            font.family: Tokens.font.body.medium.family
                            font.pixelSize: Math.round(cell.height * 0.44)
                            font.weight: Font.DemiBold
                            color: Colours.palette.m3onSurface
                            opacity: {
                                if (!cell.empty)
                                    return 0;
                                return cell.lit ? 0.2 : 0.3;
                            }
                            z: 4

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: 200
                                }
                            }
                        }

                        MouseArea {
                            id: cellHover

                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            z: -1

                            onPositionChanged: {
                                if (board.settled)
                                    root.selectedId = cell.workspaceId;
                            }
                            onClicked: {
                                root.focusWorkspace(cell.workspaceId);
                                root.screenState.dashboard = false;
                            }
                        }

                        DropArea {
                            id: dropTarget

                            anchors.fill: parent

                            onDropped: dropped => {
                                const client = ghost.client;
                                if (!client) {
                                    dropped.accept();
                                    return;
                                }

                                const screenX = cell.areaX + (dropped.x - cell.insetX) / cell.factor;
                                const screenY = cell.areaY + (dropped.y - cell.insetY) / cell.factor;

                                if (client.workspace.id !== cell.workspaceId) {
                                    root.moveClient(client.address, cell.workspaceId);
                                    dropped.accept();
                                    return;
                                }

                                if (client.floating) {
                                    const x = Math.round(screenX - client.size[0] / 2);
                                    const y = Math.round(screenY - client.size[1] / 2);
                                    Hypr.dispatch(Hypr.usingLua ? `hl.dsp.window.move({ window = "address:${client.address}", x = ${x}, y = ${y} })` : `movewindowpixel exact ${x} ${y},address:${client.address}`);
                                } else {
                                    const under = cell.windowAt(screenX, screenY, client.address);
                                    if (under && !under.floating && Hypr.usingLua)
                                        Hypr.dispatch(`hl.dsp.window.swap({ window = "address:${client.address}", target = "address:${under.address}" })`);
                                }

                                dropped.accept();
                            }
                        }
                    }
                }
            }

            Rectangle {
                id: ghost

                property var client: null
                property bool dragging: false

                visible: ghost.client !== null && ghost.dragging
                radius: Tokens.rounding.small
                color: Colours.palette.m3surfaceContainer
                border.color: Colours.palette.m3secondary
                border.width: 2
                opacity: 0.92
                z: 100

                Drag.active: ghost.visible
                Drag.source: ghost
                Drag.hotSpot.x: ghost.width / 2
                Drag.hotSpot.y: ghost.height / 2

                ScreencopyView {
                    anchors.fill: parent
                    anchors.margins: 2
                    captureSource: ghost.client ? root.toplevelFor(ghost.client) : null
                    live: root.observing
                    paintCursor: false
                }
            }
        }
    }
}

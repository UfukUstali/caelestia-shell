import QtQuick
import QtQuick.Layouts
import Caelestia.Config

RowLayout {
    id: root

    required property var lock
    required property real baseWidth
    readonly property real preferredWidth: baseWidth + (weather.showForecast ? Math.max(0, baseWidth - center.centerWidth - spacing * 2) * 0.25 : 0)

    spacing: Tokens.spacing.largeIncreased * 2

    WeatherInfo {
        id: weather

        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.alignment: Qt.AlignVCenter
        rootHeight: root.height
    }

    Center {
        id: center

        lock: root.lock
    }

    Media {
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.alignment: Qt.AlignVCenter
        lock: root.lock
    }
}

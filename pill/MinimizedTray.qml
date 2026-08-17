pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "Singletons"

/**
 * Row of icon buttons for windows parked in the minimize stash (Super+M).
 * Clicking one moves it back to the workspace this pill's monitor is showing.
 *
 * The stash is a niri workspace named "minimized"; see [[Niri]] for why, and for
 * the one config line it needs. Without that line the list is empty and the row
 * collapses, which is the same as having nothing minimized.
 */
Row {
    id: root

    property real s: 1
    property string screenName: ""
    spacing: 8 * s

    readonly property var items: Niri.minimizedWindows
    readonly property int count: items.length

    /**
     * Resolve an icon path for a window by matching its app id to a desktop
     * entry id (the two often differ from the icon-theme name), with a direct
     * icon-theme lookup as fallback.
     */
    function iconFor(t) {
        var cls = t && t.app_id ? t.app_id : "";
        if (!cls)
            return "";
        var apps = DesktopEntries.applications.values;
        for (var i = 0; i < apps.length; i++) {
            var e = apps[i];
            if (e && e.id && e.id.toLowerCase() === cls.toLowerCase() && e.icon)
                return Quickshell.iconPath(e.icon, "application-x-executable");
        }
        return Quickshell.iconPath(cls, "application-x-executable");
    }

    Repeater {
        model: root.items

        delegate: Item {
            id: chip
            required property var modelData
            width: 18 * root.s
            height: 18 * root.s

            readonly property string iconSrc: root.iconFor(chip.modelData)

            Image {
                anchors.fill: parent
                sourceSize.width: Math.round(36 * root.s)
                sourceSize.height: Math.round(36 * root.s)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                source: chip.iconSrc
                opacity: area.containsMouse ? 1 : 0.78
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }
            }

            MouseArea {
                id: area
                anchors.fill: parent
                anchors.margins: -3 * root.s
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                /**
                 * Restore onto the monitor this pill lives on, so the window
                 * comes back where it was clicked rather than wherever focus
                 * happens to be.
                 */
                onClicked: {
                    var ws = Niri.restoreTargetOn(root.screenName);
                    if (ws)
                        Niri.restore(chip.modelData.id, ws.output, ws.idx);
                }
            }

            Tooltip {
                s: root.s
                placement: "below"
                title: chip.modelData.title || ""
                show: area.containsMouse
            }
        }
    }
}

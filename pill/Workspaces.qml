pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "Singletons"

/**
 * Workspace dots for one monitor. No numbers, no icons. Active one is a larger
 * filled vermillion dot; the rest are small and dim, brightening on hover.
 * Clicking a dot focuses that workspace. The active marker tracks the monitor's
 * live active workspace from [[Niri]].
 *
 * The strip is simply the workspaces niri has on this output, in its order.
 * Hyprland needed workspace rules unioned in, because a ruled-but-unvisited
 * workspace did not exist yet and would have been missing from the strip. niri
 * has no such gap: workspaces are created and destroyed as you use them and the
 * event stream always carries the full set, so the live list is already
 * complete.
 *
 * niri keeps one empty workspace at the end of every output, so the strip
 * carries a trailing dot with nothing on it. That is the compositor's own model
 * showing through, the same as the overview shows it, not an off-by-one.
 */
Item {
    id: workspaces

    property string screenName: ""
    property real s: 1
    property real stickW: 17 * s
    property real dotW: 5 * s
    property real gap: 4 * s

    /**
     * Per-output workspace indices, ascending. These are niri's `idx`, which is
     * a position rather than an identity: it shifts when workspaces are added,
     * removed or re-ordered. That is fine for a strip that redraws from the
     * event stream anyway, and it is what focus-workspace takes.
     *
     * Named workspaces are left out. They stand in for Hyprland's special
     * workspaces here — the minimize stash, the private space — and those never
     * had dots either; the pill announces them by swapping the clock for their
     * name instead. See [[Pill]].specialView.
     */
    readonly property var range: {
        var out = [];
        var wss = Niri.workspacesOn(screenName);
        for (var i = 0; i < wss.length; i++)
            if (!wss[i].name)
                out.push(wss[i].idx);
        return out;
    }

    /** Empty while a named workspace is up, so no dot reads as active there. */
    readonly property string activeName: {
        var ws = Niri.activeWorkspaceOn(screenName);
        return ws && !ws.name ? String(ws.idx) : "";
    }

    property int hoverIndex: -1

    readonly property int activeIndex: range.indexOf(parseInt(activeName))

    /**
     * Centre x of a dot slot from target layout widths (active stick is wider).
     * Uses the animation end values, so a focus marker aimed here lands where
     * the dot settles and doesn't chase the width Behavior.
     */
    function slotCenterX(idx) {
        let x = 0;
        for (let i = 0; i < idx; i++)
            x += (i === activeIndex ? stickW : dotW) + gap;
        return x + (idx === activeIndex ? stickW : dotW) / 2;
    }

    readonly property point activeDotPoint: {
        void workspaces.activeName;
        void workspaces.width;
        return Qt.point(slotCenterX(Math.max(0, activeIndex)), height / 2);
    }

    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    RowLayout {
        id: row
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: workspaces.gap

        Repeater {
            model: workspaces.range

            delegate: Item {
                id: slot

                required property var modelData
                required property int index

                readonly property string wsName: String(modelData)
                readonly property bool isActive: workspaces.activeName === wsName

                Layout.preferredWidth: slot.isActive ? workspaces.stickW : workspaces.dotW
                Layout.preferredHeight: 22 * workspaces.s
                Behavior on Layout.preferredWidth { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width
                    height: workspaces.dotW
                    radius: height / 2
                    color: slot.isActive ? Theme.vermLit : Theme.cream
                    opacity: slot.isActive ? 1.0 : (area.containsMouse ? 0.7 : 0.3)
                    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                }

                MouseArea {
                    id: area
                    anchors.fill: parent
                    anchors.leftMargin: -workspaces.gap / 2
                    anchors.rightMargin: -workspaces.gap / 2
                    anchors.topMargin: -8 * workspaces.s
                    anchors.bottomMargin: -8 * workspaces.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Niri.focusWorkspace(workspaces.screenName, slot.wsName)
                    onContainsMouseChanged: {
                        if (containsMouse)
                            workspaces.hoverIndex = slot.index;
                        else if (workspaces.hoverIndex === slot.index)
                            workspaces.hoverIndex = -1;
                    }
                }
            }
        }
    }
}

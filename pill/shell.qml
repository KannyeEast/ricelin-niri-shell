//@ pragma UseQApplication

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Singletons"

/**
 * Washi pill top shell. Each monitor carries two layer-shell windows:
 *
 *  - `reserve` is a zero-content strip that only claims an exclusive zone the
 *    height of the rest pill, so tiled windows always sit below the pill even
 *    while it is expanded or a surface is open.
 *  - `overlay` is a full-screen transparent Overlay layer hosting the single
 *    morphing pill anchored at top-centre. The pill never moves windows and is
 *    never re-parented; it just grows in place, so every surface grows out of
 *    the rest pill instead of popping up as a separate panel.
 *
 * Input is routed by the window mask. While the pill is collapsed the mask is
 * the pill rect only, so the rest of the screen clicks through to windows.
 * While the pill is expanded (hovered/pinned) or a surface is open the mask is
 * cleared so the whole layer catches clicks. A backdrop press dismisses, and
 * keyboard focus is taken on demand so Escape closes the open surface.
 */
ShellRoot {
    id: root

    property string openMon: ""
    property string openSurface: ""
    property string peekMon: ""

    /**
     * Nothing to pull: niri's event stream pushes a complete snapshot as soon as
     * it connects and only deltas after that, so there is no stale model to
     * re-fetch. Kept as a call so the startup sequence still reads in order, and
     * because [[Niri]] keeps the same no-op for ported call sites.
     */
    function refresh() {
        Niri.refresh();
    }

    Component.onCompleted: {
        refresh();
        Devices.restore();
        void GameMode.active;
    }

    /**
     * After an update relaunches the shell, raise a one-shot toast naming what
     * landed, so the apply ends in a confirmation instead of a silent restart. The
     * updater drops the marker just before it restarts; the short delay lets the
     * notification server own the bus before we post to it, and the marker is
     * removed as it is read so the toast only ever fires once.
     */
    Timer {
        interval: 2500
        running: true
        onTriggered: updatedToast.running = true
    }
    Process {
        id: updatedToast
        command: ["sh", "-c",
            "m=\"${XDG_STATE_HOME:-$HOME/.local/state}/ricelin/updated\"; [ -f \"$m\" ] || exit 0; "
            + "b=$(cat \"$m\"); rm -f \"$m\"; "
            + "gdbus call --session --dest org.freedesktop.Notifications "
            + "--object-path /org/freedesktop/Notifications "
            + "--method org.freedesktop.Notifications.Notify "
            + "Ricelin 0 '' 'Ricelin updated' \"$b\" '[]' '{}' 5000 >/dev/null 2>&1"]
    }

    Binding {
        target: Notifs
        property: "dnd"
        value: Flags.dnd
    }

    PanelWindow {
        id: inhibitWin
        visible: Flags.keepAwake
        implicitWidth: 1
        implicitHeight: 1
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.namespace: "pill-inhibit"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        anchors { top: true; left: true }
        IdleInhibitor { window: inhibitWin; enabled: Flags.keepAwake }
    }

    /**
     * The Wayland IdleInhibitor above only pauses the compositor's own idle
     * (DPMS); hypridle runs its own timer and never sees it, so the lock still
     * fired with keep-awake on. A logind idle inhibitor is the wire hypridle
     * does respect, so hold one for as long as the flag is set.
     */
    Process {
        running: Flags.keepAwake
        command: ["systemd-inhibit", "--what=idle:sleep", "--who=Ricelin",
                  "--why=keep awake", "--mode=block", "sleep", "infinity"]
    }

    /**
     * The Hyprland build kept an allowlist of raw events here, because every
     * interesting one had to be answered with a three-call model refresh and
     * title spam would otherwise have driven it constantly. niri pushes deltas
     * that [[Niri]] applies to its own properties, so the bindings that read
     * those properties re-evaluate on their own and there is nothing to filter.
     */

    /**
     * An empty monitor argument resolves to the focused output here, so a
     * keybind can call `qs ipc call pill mixer ""` without first asking the
     * compositor which monitor it is on.
     */
    function toggleSurface(mon, surface) {
        if (!mon || mon.length === 0)
            mon = Niri.focusedOutput;
        if (root.openMon === mon && root.openSurface === surface) {
            root.close();
            return;
        }
        root.openMon = mon;
        root.openSurface = surface;
    }

    function close() {
        root.openMon = "";
        root.openSurface = "";
    }

    function peek(mon) {
        root.peekMon = root.peekMon === mon ? "" : mon;
    }

    IpcHandler {
        target: "pill"
        function mixer(mon: string): void { root.toggleSurface(mon, "mixer"); }
        function calendar(mon: string): void { root.toggleSurface(mon, "calendar"); }
        function launcher(mon: string): void { root.toggleSurface(mon, "launcher"); }
        function power(mon: string): void { root.toggleSurface(mon, "power"); }
        function link(mon: string): void { root.toggleSurface(mon, "link"); }
        function battery(mon: string): void { root.toggleSurface(mon, "battery"); }
        function settings(mon: string): void { root.toggleSurface(mon, "settings"); }
        function keybinds(mon: string): void { root.toggleSurface(mon, "keybinds"); }
        function recorder(mon: string): void { root.toggleSurface(mon, "recorder"); }
        function screenrec(mon: string): void { root.toggleSurface(mon, "recorder"); }
        function record(mon: string): void { root.toggleSurface(mon, "recorder"); }

        /**
         * Quick-record keybind (SUPER+D): one button cycles the whole flow with no
         * surface. Recording → stop. Counting down → cancel. A chooser already up
         * on this monitor → dismiss. Otherwise open the standalone source chooser on
         * the focused monitor `mon`, so only that pill renders it.
         */
        function quickRecord(mon: string): void {
            if (ScreenRec.recording) {
                ScreenRec.stop();
            } else if (ScreenRec.counting) {
                ScreenRec.cancel();
            } else if (ScreenRec.quickChoosing) {
                ScreenRec.quickChoosing = false;
                ScreenRec.quickScreenChoosing = false;
            } else {
                // Each pill shows the chooser only when quickMon names its own
                // screen, so an empty one has to be resolved here or the
                // chooser opens on nothing at all.
                ScreenRec.quickMon = mon && mon.length > 0 ? mon : Niri.focusedOutput;
                ScreenRec.quickScreenChoosing = false;
                ScreenRec.quickChoosing = true;
            }
        }
        function gameMode(mon: string): void { Flags.gameMode = !Flags.gameMode; }
        function sysmon(mon: string): void { root.toggleSurface(mon, "sysmon"); }
        function system(mon: string): void { root.toggleSurface(mon, "sysmon"); }
        function clipboard(mon: string): void { root.toggleSurface(mon, "clipboard"); }
        function wallpaper(mon: string): void { root.toggleSurface(mon, "wallpaper"); }
        function media(mon: string): void {
            if (Players.list.length > 0)
                root.toggleSurface(mon, "media");
        }
        function peek(mon: string): void { root.peek(mon); }
        function hide(): void { root.close(); }

        /** Opens any surface by name, settings sub-pages included; dev and scripting door. */
        function page(mon: string, name: string): void { root.toggleSurface(mon, name); }

        /**
         * The two halves of the SUPER+M minimize toggle. A desktop window drops
         * into the stash; a stashed window comes back to the workspace you are
         * looking at, so the same key hides and restores.
         *
         * These took a window address on Hyprland because a helper script had
         * already run `hyprctl activewindow` to find it. niri's event stream
         * carries the focused window continuously, so the arguments and the
         * script both go away and the keybind can call these bare:
         *
         *   Mod+M { spawn "qs" "ipc" "call" "pill" "minimizeToggle"; }
         */
        function minimizeWindow(): void {
            Niri.minimize();
        }

        /** Newest first: the stash is a stack, so this undoes the last minimize. */
        function restoreWindow(): void {
            var stashed = Niri.minimizedWindows;
            if (stashed.length > 0)
                root.restoreTo(stashed[stashed.length - 1].id);
        }

        /**
         * Stash the focused window, unless you are looking at the stash itself,
         * in which case pull that window back out. One key does both halves, the
         * way the visible special workspace signalled it on Hyprland.
         */
        function minimizeToggle(): void {
            var stash = Niri.minimizedWorkspace;
            var ws = Niri.focusedWorkspace;
            if (stash && ws && ws.id === stash.id) {
                if (Niri.focusedWindowId >= 0)
                    root.restoreTo(Niri.focusedWindowId);
                return;
            }
            Niri.minimize();
        }
    }

    /** Send a stashed window back to a real workspace on this output, and follow it. */
    function restoreTo(windowId) {
        var target = Niri.restoreTargetOn(Niri.focusedOutput);
        if (target)
            Niri.restore(windowId, target.output, target.idx);
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: reserve
            required property var modelData
            readonly property real s: modelData ? (modelData.height / 1080) * Flags.uiScale : 1
            readonly property real topGap: 8 * Flags.topGap * s
            readonly property real restHeight: 38 * s

            /** Trimming the reserved band below the pill's bottom lets windows climb, so App gap sets the pill-to-window air without touching the desktop gaps_out. */
            readonly property real reservedH: Math.max(0, restHeight + topGap - 12 * (1 - Flags.appGap) * s)

            readonly property real gameBarH: 34 * s

            screen: modelData
            color: "transparent"
            exclusionMode: ExclusionMode.Normal
            exclusiveZone: Flags.gameMode ? gameBarH : reservedH
            aboveWindows: true

            anchors { top: true; left: true; right: true }
            implicitHeight: Flags.gameMode ? gameBarH : reservedH

            mask: emptyReserve
            Region { id: emptyReserve }
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: overlay
            required property var modelData
            readonly property real s: modelData ? (modelData.height / 1080) * Flags.uiScale : 1
            readonly property real topGap: 8 * Flags.topGap * s
            readonly property string surface: root.openMon === modelData.name ? root.openSurface : ""
            readonly property bool surfaceOpen: surface.length > 0
            readonly property bool modal: pill.authPending ? false : (surfaceOpen || pill.held || pill.quickChoosing)

            /**
             * True while a fullscreen client is visible on this monitor. The
             * pill then retracts off the top edge and the whole layer becomes
             * click-through so fullscreen content owns the screen.
             *
             * Read off wlr-foreign-toplevel rather than the compositor's own
             * IPC: niri's Window objects carry no fullscreen flag (there is a
             * `fullscreen-window` action, but no state to read back), while the
             * foreign-toplevel protocol reports both `fullscreen` and the
             * screens a toplevel is on. That protocol is also compositor-neutral,
             * so this stops being the one place that has to know which
             * compositor is running.
             */
            readonly property bool monFullscreen: {
                var tls = ToplevelManager.toplevels.values;
                for (var i = 0; i < tls.length; i++) {
                    var t = tls[i];
                    if (!t || !t.fullscreen)
                        continue;
                    var screens = t.screens;
                    for (var j = 0; j < screens.length; j++)
                        if (screens[j] === modelData)
                            return true;
                }
                return false;
            }

            onMonFullscreenChanged: if (monFullscreen) {
                if (root.openMon === modelData.name) root.close();
                if (root.peekMon === modelData.name) root.peekMon = "";
                pill.pinned = false;
            }

            screen: modelData
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: ((surfaceOpen || pill.quickChoosing) && !pill.authPending) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            WlrLayershell.namespace: "pill"

            anchors { top: true; left: true; right: true; bottom: true }

            mask: monFullscreen ? hiddenRegion : (modal ? fullRegion : pillRegion)
            Region { id: hiddenRegion }
            Region {
                id: pillRegion
                readonly property real baseW: Math.max(pill.width, pill.targetW)
                x: pill.x + (pill.width - baseW) / 2
                y: pill.y
                width: baseW + pill.inputPadRight
                height: Math.max(pill.height, pill.targetH)
            }
            Region {
                id: fullRegion
                width: overlay.width
                height: overlay.height
            }

            MouseArea {
                anchors.fill: parent
                enabled: overlay.modal
                acceptedButtons: Qt.AllButtons
                onPressed: (mouse) => {
                    if (pill.quickChoosing) {
                        ScreenRec.quickChoosing = false;
                        ScreenRec.quickScreenChoosing = false;
                    } else if (overlay.surfaceOpen) {
                        var inside = mouse.x >= pillRegion.x && mouse.x <= pillRegion.x + pillRegion.width
                            && mouse.y >= pillRegion.y && mouse.y <= pillRegion.y + pillRegion.height;
                        if (!inside)
                            root.close();
                        else if (mouse.y <= pillRegion.y + 40 * pill.s)
                            pill.surfaceBack();
                    } else {
                        pill.pinned = false;
                        root.peekMon = "";
                    }
                }
            }

            FocusScope {
                id: focusScope
                anchors.fill: parent
                focus: overlay.surfaceOpen || pill.quickChoosing

                HoverHandler {
                    onHoveredChanged: pill.hovered = hovered
                }
                Keys.onEscapePressed: {
                    if (pill.quickChoosing) {
                        ScreenRec.quickChoosing = false;
                        ScreenRec.quickScreenChoosing = false;
                    } else if (!pill.keybindsBack()) {
                        root.close();
                    }
                }
                Keys.onUpPressed: (e) => {
                    if (pill.keybindsOpen && !pill.keybindsListening) { pill.keybindsMove(-1); e.accepted = true; return; }
                    e.accepted = pill.mixerStep(1) || pill.recorderStep(5) || pill.settingsMove(-1);
                }
                Keys.onDownPressed: (e) => {
                    if (pill.keybindsOpen && !pill.keybindsListening) { pill.keybindsMove(1); e.accepted = true; return; }
                    e.accepted = pill.mixerStep(-1) || pill.recorderStep(-5) || pill.settingsMove(1);
                }
                Keys.onLeftPressed: (e) => {
                    if (pill.mixerOpen) { pill.mixerFocusMove(-1); e.accepted = true; }
                    else if (pill.wallpaperOpen) { pill.wallpaperMove(-1); e.accepted = true; }
                    else if (pill.powerOpen) { pill.powerMove(-1); e.accepted = true; }
                    else if (pill.recorderOpen) { e.accepted = pill.recorderStep(-5); }
                    else if (pill.settingsLike) { pill.settingsAdjust(-1); e.accepted = true; }
                }
                Keys.onRightPressed: (e) => {
                    if (pill.mixerOpen) { pill.mixerFocusMove(1); e.accepted = true; }
                    else if (pill.wallpaperOpen) { pill.wallpaperMove(1); e.accepted = true; }
                    else if (pill.powerOpen) { pill.powerMove(1); e.accepted = true; }
                    else if (pill.recorderOpen) { e.accepted = pill.recorderStep(5); }
                    else if (pill.settingsLike) { pill.settingsAdjust(1); e.accepted = true; }
                }

                /**
                 * Return/Enter/Space: the wallpaper strip applies its focused
                 * thumb on every press; the power surface fires a safe tile on
                 * the first press and, for a destructive tile, holds the heat
                 * fill across autorepeat presses (drained on release). Autorepeat
                 * is swallowed for everything else so a held key never re-fires.
                 */
                Keys.onPressed: (e) => {
                    if (pill.wallpaperOpen && !pill.wallpaperSearching
                        && e.text.length === 1 && e.text > " ") {
                        pill.wallpaperType(e.text);
                        e.accepted = true;
                        return;
                    }
                    if (e.key !== Qt.Key_Return && e.key !== Qt.Key_Enter && e.key !== Qt.Key_Space)
                        return;
                    if (pill.wallpaperOpen) {
                        if (!e.isAutoRepeat) pill.wallpaperActivate();
                        e.accepted = true;
                    } else if (pill.powerOpen) {
                        if (!e.isAutoRepeat) pill.powerPress();
                        e.accepted = true;
                    } else if (pill.settingsLike) {
                        if (!e.isAutoRepeat) pill.settingsActivate();
                        e.accepted = true;
                    } else if (pill.keybindsOpen && !pill.keybindsListening) {
                        if (!e.isAutoRepeat) pill.keybindsActivate();
                        e.accepted = true;
                    }
                }
                Keys.onReleased: (e) => {
                    if (e.isAutoRepeat)
                        return;
                    if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space)
                        && pill.powerOpen) {
                        pill.powerRelease();
                        e.accepted = true;
                    }
                }

                Pill {
                    id: pill
                    anchors.top: parent.top
                    anchors.topMargin: pill.mode === "game" ? 0 : overlay.topGap
                    anchors.horizontalCenter: parent.horizontalCenter

                    Behavior on anchors.topMargin {
                        NumberAnimation {
                            duration: Motion.morph
                            easing.type: Motion.easeMorph
                            easing.bezierCurve: Motion.morphCurve
                        }
                    }
                    s: overlay.s
                    screenName: overlay.modelData.name
                    barWindow: overlay
                    surface: overlay.surface
                    forcePinned: root.peekMon === overlay.modelData.name

                    opacity: overlay.monFullscreen ? 0 : 1
                    Behavior on opacity {
                        NumberAnimation {
                            duration: Motion.morph
                            easing.type: Motion.easeMorph
                            easing.bezierCurve: Motion.morphCurve
                        }
                    }
                    transform: Translate {
                        y: overlay.monFullscreen ? -(pill.height + overlay.topGap) : 0
                        Behavior on y {
                            NumberAnimation {
                                duration: Motion.morph
                                easing.type: Motion.easeMorph
                                easing.bezierCurve: Motion.morphCurve
                            }
                        }
                    }

                    onRequestSurface: (name) => root.toggleSurface(overlay.modelData.name, name)
                    onRequestClose: root.close()
                }
            }

            onSurfaceOpenChanged: if (surfaceOpen) focusScope.forceActiveFocus()

            Connections {
                target: pill
                function onQuickChoosingChanged() {
                    if (pill.quickChoosing)
                        focusScope.forceActiveFocus();
                }
                function onWallpaperSearchingChanged() {
                    if (!pill.wallpaperSearching && overlay.surfaceOpen)
                        focusScope.forceActiveFocus();
                }
                function onKeybindsListeningChanged() {
                    if (!pill.keybindsListening && overlay.surfaceOpen)
                        focusScope.forceActiveFocus();
                }
            }
        }
    }
}

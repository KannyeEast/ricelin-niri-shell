pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Compositor bridge, standing in for the Quickshell.Hyprland module niri has no
 * equivalent of. One long-lived `niri msg --json event-stream` carries state in;
 * actions go out over short-lived `niri msg` spawns, which is cheap because they
 * only ever fire on user input.
 *
 * niri sends the complete state up-front and then only deltas, so there is
 * nothing to poll and no refresh to call — `WorkspacesChanged` and
 * `WindowsChanged` each replace their list wholesale, and anything missing from
 * them was deleted. That is why `refresh()` below is deliberately a no-op: it
 * exists so call sites ported from Hyprland keep reading naturally.
 *
 * Monitors are derived rather than requested. The event stream carries no output
 * events, but every workspace names the output it sits on, so the set of outputs
 * and their active workspaces falls out of the workspace list for free. Physical
 * geometry, where a surface needs it, comes from Quickshell.screens.
 */
Singleton {
    id: root

    /** Whole workspace list, newest snapshot from the compositor. */
    property var workspaces: []

    /** Whole window list. Ported code calls these toplevels. */
    property var windows: []

    /** Id of the focused window, or -1 when nothing is focused. */
    property int focusedWindowId: -1

    /** Overview state, for surfaces that want to retract while it is open. */
    property bool overviewOpen: false

    /** True once the stream has delivered its first snapshot. */
    property bool ready: false

    /** Mirrors Hyprland.onRawEvent so ported Connections blocks keep working. */
    signal rawEvent(string name, var data)

    readonly property var focusedWorkspace: {
        for (var i = 0; i < workspaces.length; i++)
            if (workspaces[i].is_focused)
                return workspaces[i];
        return null;
    }

    readonly property string focusedOutput: focusedWorkspace ? (focusedWorkspace.output || "") : ""

    /**
     * Outputs that currently hold a workspace, each with the workspace active on
     * it. Replaces Hyprland.monitors.values for the name/activeWorkspace lookups
     * the pill does; anything needing pixels should use Quickshell.screens.
     */
    readonly property var monitors: {
        var seen = ({});
        var out = [];
        for (var i = 0; i < workspaces.length; i++) {
            var ws = workspaces[i];
            if (!ws.output || seen[ws.output])
                continue;
            seen[ws.output] = true;
            out.push({
                name: ws.output,
                activeWorkspace: root.activeWorkspaceOn(ws.output),
                focused: ws.output === root.focusedOutput
            });
        }
        return out;
    }

    function activeWorkspaceOn(output) {
        for (var i = 0; i < workspaces.length; i++)
            if (workspaces[i].output === output && workspaces[i].is_active)
                return workspaces[i];
        return null;
    }

    function workspaceById(id) {
        for (var i = 0; i < workspaces.length; i++)
            if (workspaces[i].id === id)
                return workspaces[i];
        return null;
    }

    function windowById(id) {
        for (var i = 0; i < windows.length; i++)
            if (windows[i].id === id)
                return windows[i];
        return null;
    }

    function windowsOn(workspaceId) {
        return windows.filter(function (w) { return w.workspace_id === workspaceId; });
    }

    /** No-op. The stream is authoritative; kept so ported call sites still read. */
    function refresh() {}

    /**
     * Fire a compositor action. Args are passed through verbatim, so this maps
     * one-to-one onto what you would type: action("focus-workspace", ["2"]).
     */
    function action(name, args) {
        var argv = ["niri", "msg", "action", name];
        if (args)
            for (var i = 0; i < args.length; i++)
                argv.push(String(args[i]));
        actionProc.command = argv;
        actionProc.running = true;
    }

    Process { id: actionProc }

    /**
     * niri msg --json event-stream prints one Event per line and keeps the pipe
     * open, which is the same shape Cava and Cliphist already consume. The
     * lower-level $NIRI_SOCKET route exists too, but Quickshell's Socket type is
     * not used anywhere else in this tree and may not be in the pinned build.
     */
    Process {
        id: stream
        running: true
        command: ["niri", "msg", "--json", "event-stream"]

        stdout: SplitParser {
            onRead: (line) => root.ingest(line)
        }

        // niri restarting takes the pipe with it; come back rather than going
        // permanently blind. The delay keeps a hard failure from spinning.
        onExited: {
            root.ready = false;
            retry.restart();
        }
    }

    Timer {
        id: retry
        interval: 2000
        onTriggered: stream.running = true
    }

    /**
     * Each line is one Event object with exactly one key naming the variant, so
     * the key is the event name and its value is the payload. The Ok/Err guard
     * below only matters on the raw socket, where requests are acknowledged
     * first; it is harmless here and keeps that route a drop-in.
     */
    function ingest(line) {
        if (!line || line.length === 0)
            return;

        var msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            console.warn("Niri: unparsable line:", line);
            return;
        }

        if (msg.Err !== undefined) {
            console.warn("Niri: request rejected:", JSON.stringify(msg.Err));
            return;
        }
        if (msg.Ok !== undefined)
            return;

        for (var name in msg) {
            root.apply(name, msg[name]);
            root.rawEvent(name, msg[name]);
            break;
        }
    }

    function apply(name, d) {
        switch (name) {
        case "WorkspacesChanged":
            // Replaces the list entirely; absent workspaces were deleted.
            workspaces = d.workspaces;
            ready = true;
            break;

        case "WorkspaceActivated": {
            // One workspace becomes active on its output. If it also took focus,
            // every other workspace everywhere loses focus.
            var target = workspaceById(d.id);
            if (!target)
                break;
            var next = workspaces.map(function (ws) {
                var copy = Object.assign({}, ws);
                if (ws.output === target.output)
                    copy.is_active = ws.id === d.id;
                if (d.focused)
                    copy.is_focused = ws.id === d.id;
                return copy;
            });
            workspaces = next;
            break;
        }

        case "WorkspaceActiveWindowChanged":
            workspaces = workspaces.map(function (ws) {
                if (ws.id !== d.workspace_id)
                    return ws;
                var copy = Object.assign({}, ws);
                copy.active_window_id = d.active_window_id;
                return copy;
            });
            break;

        case "WorkspaceUrgencyChanged":
            workspaces = workspaces.map(function (ws) {
                if (ws.id !== d.id)
                    return ws;
                var copy = Object.assign({}, ws);
                copy.is_urgent = d.urgent;
                return copy;
            });
            break;

        case "WindowsChanged":
            windows = d.windows;
            for (var i = 0; i < windows.length; i++)
                if (windows[i].is_focused)
                    focusedWindowId = windows[i].id;
            break;

        case "WindowOpenedOrChanged": {
            var w = d.window;
            var found = false;
            var list = windows.map(function (existing) {
                if (existing.id !== w.id)
                    // A focused window implies every other one is not.
                    return w.is_focused && existing.is_focused
                        ? Object.assign({}, existing, { is_focused: false })
                        : existing;
                found = true;
                return w;
            });
            if (!found)
                list.push(w);
            windows = list;
            if (w.is_focused)
                focusedWindowId = w.id;
            break;
        }

        case "WindowClosed":
            windows = windows.filter(function (w) { return w.id !== d.id; });
            if (focusedWindowId === d.id)
                focusedWindowId = -1;
            break;

        case "WindowFocusChanged":
            focusedWindowId = d.id === null || d.id === undefined ? -1 : d.id;
            windows = windows.map(function (w) {
                var wanted = w.id === focusedWindowId;
                return w.is_focused === wanted
                    ? w
                    : Object.assign({}, w, { is_focused: wanted });
            });
            break;

        case "WindowUrgencyChanged":
            windows = windows.map(function (w) {
                if (w.id !== d.id)
                    return w;
                return Object.assign({}, w, { is_urgent: d.urgent });
            });
            break;

        case "OverviewOpenedOrClosed":
            overviewOpen = d.is_open;
            break;

        default:
            // Casts, keyboard layouts, config reloads and window layouts are
            // still delivered through rawEvent for anything that wants them.
            break;
        }
    }
}

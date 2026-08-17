pragma Singleton

import QtQuick
import Quickshell

/**
 * Every path the shell reaches outside itself, in one place.
 *
 * The shell used to hardcode `~/.config/hypr/...` for its own helper scripts,
 * which tied a Quickshell config to a Hyprland config directory that had no
 * reason to exist on a niri machine. Scripts now resolve relative to the repo,
 * so the tree can be checked out anywhere, run as a submodule, or symlinked into
 * place, and nothing has to be installed beside it.
 */
Singleton {
    id: root

    /**
     * The repo's own scripts.
     *
     * `qs -c pill` resolves to <config>/quickshell/pill/shell.qml, so shellDir
     * is the pill directory and the repo root is one above it. The `..` is left
     * unresolved rather than trimmed off the string: shellPath is the documented
     * way to ask Quickshell where it is, and every consumer of these paths is
     * either exec or a file read, both of which resolve `..` themselves.
     */
    readonly property string scripts: Quickshell.shellPath("../scripts")

    function script(name) {
        return root.scripts + "/" + name;
    }

    /**
     * Hyprland config files belonging to surfaces that are not ported yet.
     *
     * These are the settings surfaces that rewrite compositor config — keybinds,
     * layout, animations, input, outputs, workspaces, window rules. They still
     * read and write Hyprland's Lua, so they are inert on niri: the files do not
     * exist, the surfaces open and show nothing, and nothing is damaged.
     *
     * They deliberately still point at ~/.config/hypr. Aiming them at
     * ~/.config/niri without porting their contents first would mean writing Lua
     * into a directory niri parses as KDL, which is a much worse failure than
     * doing nothing: it would take the whole config down on the next reload.
     *
     * When each surface is ported it should move off this function entirely and
     * write KDL into a file the user's config includes. Whatever still calls
     * this is what is left to do.
     */
    function hyprlandConfig(name) {
        return Quickshell.env("HOME") + "/.config/hypr/" + name;
    }
}

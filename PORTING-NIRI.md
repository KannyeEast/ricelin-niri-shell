# Porting Ricelin from Hyprland to niri

Status of the fork. The bar runs on niri and the shell is self-contained: it
carries its own scripts and resolves them relative to the repo, so nothing has
to be installed beside it and no path points into a Hyprland config directory.

`configs/hypr/` is the original upstream Hyprland config, kept for reference and
otherwise untouched. Nothing the shell runs reads from it.

## Layout

```
pill/        the bar and every surface that grows out of it   (qs -c pill)
lock/        lock surface, resident, woken by a file watch    (qs -c lock)
launcher/    app launcher, resident so it opens instantly     (qs -c launcher)
scripts/     everything the shell shells out to
configs/niri/ricelin.kdl   what niri needs to know — startup + one workspace
configs/hypr/              upstream Hyprland config, reference only
```

Scripts resolve through `Paths.script()`, which is `Quickshell.shellPath("../scripts")`
— `qs -c pill` runs `<repo>/pill/shell.qml`, so the repo root is one level up.
Check the tree out anywhere.

## What replaced `Quickshell.Hyprland`

There is no `Quickshell.Niri` module — every niri shell writes its own IPC
bridge, and `pill/Singletons/Niri.qml` is ours. One long-lived
`niri msg --json event-stream` carries state in; actions go out as short-lived
`niri msg` spawns, which is cheap because they only fire on input.

The shape of the two IPCs differs in a way that removed code rather than adding
it. Hyprland's model had to be pulled: every interesting event triggered
`refreshMonitors` + `refreshWorkspaces` + `refreshToplevels`, three round trips,
which is why `shell.qml` kept an allowlist of events worth paying for. niri
pushes a complete snapshot on connect and deltas after, so bindings re-evaluate
on their own. The allowlist and the refresh calls are gone; `Niri.refresh()` is
a documented no-op so ported call sites still read.

| Hyprland | niri |
| --- | --- |
| `Hyprland.workspaces.values` | `Niri.workspacesOn(output)` |
| `Hyprland.monitors.values` | `Niri.monitors`, or `Quickshell.screens` for pixels |
| `Hyprland.focusedMonitor.name` | `Niri.focusedOutput` |
| `Hyprland.focusedWorkspace` | `Niri.focusedWorkspace` |
| `Hyprland.toplevels.values` | `Niri.windows` |
| `Hyprland.dispatch(...)` | `Niri.action(name, args)` |
| `Hyprland.refresh*()` | nothing — the stream is authoritative |

## Decisions worth knowing

**Workspace identity.** Hyprland numbered workspaces 1–10 globally. niri creates
and destroys them as you use them, and `idx` is a *position on its output*, not
an identity — it shifts as workspaces move. The dot strip draws `idx` because
that is what you see and what `focus-workspace` takes. `id` is the stable handle
if anything needs to remember a workspace across a re-order.

**One extra dot.** niri keeps an empty workspace at the end of every output, so
the strip always shows a trailing empty dot — the compositor's model showing
through, the same as the overview shows it.

**Clicking a dot on an unfocused monitor.** Workspace indices resolve against
the *focused* output, so aiming at another monitor's workspace needs focus moved
there first. `Niri.focusWorkspace()` puts both actions in one `sh -c`; as two
separate spawns they race, and losing that race focuses the right index on the
wrong monitor.

**Special workspaces → named workspaces.** niri has none, so the minimize stash
became a workspace named `minimized`, declared in `configs/niri/ricelin.kdl`.
It persists whether or not anything is on it and is addressable by name.
Different in that it sits in the scroll order rather than overlaying, and shows
in the overview. The strip leaves named workspaces out and the pill puts their
name where the clock goes, so you can always tell you are standing on one.

**Minimize got simpler.** The Hyprland build shelled out to `minimize-toggle.sh`
so something could run `hyprctl activewindow`. niri's event stream already
carries the focused window, so the script is gone and the IPC calls take no
arguments.

**Media keys moved off the compositor.** They were `GlobalShortcut`, which rides
the `hyprland-global-shortcuts` protocol niri does not implement. Now
`IpcHandler { target: "media" }` in `Players.qml`, bound to `qs ipc call`.

**Fullscreen detection moved to a neutral protocol.** niri's IPC has a
`fullscreen-window` action but no fullscreen *state* to read back. The pill now
reads `ToplevelManager` (wlr-foreign-toplevel), which reports both `fullscreen`
and the screens a toplevel is on.

**Game mode inverted.** Hyprland could be reconfigured live, so game mode
snapshotted every decoration value, pushed zeros over the top, and pushed the
snapshot back on the way out. niri watches its config instead, so `gamemode.sh`
writes an *override layer* — `on` fills the file, `off` empties it, and coming
back is the base config being unopposed again. No snapshot to keep in sync.
Opt in by adding this at the **end** of your `config.kdl`, after your own layout,
since includes override what precedes them:

```kdl
include optional=true "ricelin-gamemode.kdl"
```

Without it, game mode still quiets notifications, pauses the visualizer, holds
the session awake and slims the bar; only the compositor decoration stays put.

**Workspace rules are gone.** `Workspacerules.qml` existed because a
ruled-but-unvisited Hyprland workspace did not exist yet and would have been
missing from the strip. niri has no such gap, so the singleton was deleted
rather than stubbed.

## Known regressions

**Recorder window snapping.** The Hyprland build piped each client's rectangle
into `slurp`, so a click snapped to a whole window; `hyprctl clients` gave
absolute screen coordinates. niri reports position relative to the *workspace
view*, which is inset by struts and by layer-shell exclusive zones — this bar's
included — and that inset is not exposed over IPC. Reconstructing absolute
coordinates means guessing our own reserved height, and being wrong by exactly
that much is worse than not snapping, because the rectangles would look
plausible and land off by ~40px every time. Region selection still works.

**Wallpaper cursor targeting.** `wallpaper.sh` used to paper the monitor under
the pointer. niri exposes output geometry but not the pointer, so it falls back
to the focused output — the same monitor except between moving the mouse to
another screen and clicking on it.

## Still to do

Everything below still reads or writes Hyprland config. These surfaces *load*
and the bar runs fine with them present — they are inert, because the `.lua`
files they edit do not exist and `hyprctl` is not there. They deliberately still
point at `~/.config/hypr` through `Paths.hyprlandConfig()`: aiming them at
`~/.config/niri` without porting their contents would write Lua into a directory
niri parses as KDL, taking the whole config down on the next reload. Whatever
still calls that function is what is left to do.

The shared piece of work is a KDL reader/writer to replace the Lua ones in
`pill/lib/`, writing to a file the user's `config.kdl` includes — the same shape
`gamemode.sh` already uses, which keeps this working on a hand-written setup and
a Nix-generated one alike, since the shell only ever owns its own file.

| Surface | Writes | niri target |
| --- | --- | --- |
| `Keybinds.qml` | `binds.lua` | `binds {}` |
| `Look.qml` | `decoration.lua` | `layout {}` |
| `AnimationSurface.qml` | `animations.lua` | `animations {}` |
| `Input.qml` | `input.lua`, `env.lua` | `input {}`, `cursor {}` |
| `Display.qml` | `monitors.lua` | `output {}` |
| `Spaces.qml` | `spaces.lua` | named workspaces |
| `SpaceApps.qml` / `Stash.qml` | `stash-apps.lua` | `window-rule {}` |

Smaller, independent items:

- **Theming.** `flavours` is the source of colour, so `Theme.qml` should read the
  active base16 scheme rather than deriving its own palette from the wallpaper.
  That means a `flavours` template for the shell and dropping `wallcolors.py`.
  Until then the bar themes itself and may not agree with alacritty and niri.
- **`NightLight.qml`** drives `hyprsunset`, which is Hyprland-only. `wlsunset` or
  `gammastep` is the swap.
- **`IdleLock.qml`** writes `hypridle.conf`. niri ships no idle daemon; `swayidle`
  is the usual answer.
- **`install.sh`** still installs a Hyprland session.

## Setup

One line at the top level of `~/.config/niri/config.kdl`:

```kdl
include "ricelin.kdl"
```

That declares the stash workspace and starts the three shells. It deliberately
contains **no keybinds** — a block of binds in an included file would silently
override whatever you set before the include, and which key opens which surface
is yours to decide. The bottom of the file is a reference list of every
`qs ipc call` the shell exposes; copy what you want into your own bindings.

`include` needs niri 25.11+; `optional=true` and `~` expansion need 26.04.

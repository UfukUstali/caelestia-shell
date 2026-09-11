# Fork customizations

Rebuilt from commits `cc3b9d79` and `095e28de` on `upstream-main` at `d8ee1e8b`.

## Shared brightness

The OSD slider, brightness shortcuts, bar scrolling and untargeted brightness IPC
set one logical level across displays. Each display maps that level into its own
`services.minBrightness` and `services.maxBrightness`, both between 0 and 1.
Defaults are 0 and 1. Hardware commands round to whole percentages.

For `~/.config/caelestia/monitors/eDP-1/shell.json`:

```json
{
  "services": {
    "minBrightness": 0.2,
    "maxBrightness": 1.0
  }
}
```

Leave the external display at the default range. Slider values of 0%, 50% and
100% then produce laptop values of 20%, 60% and 100%, and external values of
0%, 50% and 100%. Replace `eDP-1` with your actual connector name.

Both OSDs show the shared logical level. At startup, the first successful device
read seeds it without changing hardware. The first global adjustment synchronizes
all displays. A display discovered or connected after an adjustment joins that
level. Explicit `brightness setFor <monitor> <value>` remains targeted and uses
that display's logical range. The next global adjustment synchronizes it again.

Rapid input updates the desired level immediately. Hardware writes are serialized
per display. DDC writes have a 500 ms cooldown, with only the latest request kept.
Changing configured bounds remaps the current requested level.

Built-in eDP, LVDS and DSI panels use `brightnessctl -c backlight`; external
monitors use DDC or the existing Apple Studio Display backend. An external output
without a detected backend does not write to the laptop backlight.

## Idle behavior

`onlyWhenLocked` enables the idle monitor only while locked. Its timeout starts
when the compositor confirms the lock, and activity while locked restarts it.
If its idle action ran, its return action runs on activity or disabling the
monitor, including unlocking.
Upstream audio, charging and compositor inhibitors still apply.

Use these entries under `general.idle` in `~/.config/caelestia/shell.json` to lock
after 20 minutes and switch displays off after one further minute. Manual locking
also starts the one-minute screen-off timeout.

```json
{
  "general": {
    "idle": {
      "timeouts": [
        {
          "idleAction": "hl.dsp.dpms({ action = \"off\" })",
          "onlyWhenLocked": true,
          "returnAction": "hl.dsp.dpms({ action = \"on\" })",
          "timeout": 60
        },
        {
          "idleAction": "lock",
          "timeout": 1200
        }
      ]
    }
  }
}
```

The old separate 1260-second screen-off entry is unnecessary with these semantics.
Default screen-off and suspend entries are also lock-only. Existing user timeout
lists override defaults; the shell does not rewrite them.

## Appearance and authentication

The lock screen shows weather, password and username, and media. The clock includes
a colon in both 12-hour and 24-hour formats. When the hourly forecast is visible,
the layout expands both side cards equally, giving weather up to 25% more width
while keeping the clock and password centered. Expansion is capped at the screen
width with margins. Hourly columns reserve room for the time label plus padding.
The laptop forecast visibility threshold stays the same. System stats, notifications
and the lock-icon background plate are removed. Escape clears the password buffer,
preserving upstream authentication guards and biometric handling.

The compact dashboard media controls are centered, with the progress ring anchored
to the cover. Media and session GIFs and their speed/path settings are removed.
The expanded media dashboard already removed its GIF upstream. Delete obsolete
GIF settings from existing configuration files.

## Workspace dashboard tab

The dashboard includes a `Workspace` tab adapted from impasto's `OverviewPanel.qml`.
It is enabled by default through `dashboard.showWorkspace` and can be toggled in
the dashboard settings. The panel uses Caelestia colours and spacing, with no
instruction text above the grid.

The grid has up to five columns and includes workspaces 1 through
`max(10, bar.workspaces.shown)`, plus other existing positive workspace IDs.
Special workspaces are excluded. Each workspace shows the wallpaper and live
window previews positioned using its monitor's scale, rotation and reserved
edges. Empty workspaces show their number. Selection and active-workspace rings
mark the keyboard target and current workspace.

- Arrow keys move the selection, wrapping across the workspace list. Up and down
  move by one row. Enter activates the selection and closes the dashboard.
- Clicking a workspace or window focuses it and closes the dashboard. Escape
  closes the dashboard.
- Right-clicking a window closes it. Middle-clicking toggles floating. Both keep
  the dashboard open.
- Dragging a window to another workspace moves it without following it. Within
  the same workspace, dragging a floating window repositions it. Dropping a tiled
  window onto another tiled window swaps them when using Hyprland's Lua API.

The tab receives keyboard focus while open and disables horizontal dashboard
page swiping so window dragging owns the gesture. Horizontal scrolling does not
send scrolling-layout commands to Hyprland.

Client and monitor data refresh every 500 ms while the tab is open. Client updates
pause during a window drag. Captures prefer native window-address matching, with
app ID and title matching as a fallback. Identical app IDs and titles can therefore
share a fallback preview.

The implementation is in `modules/dashboard/Workspace.qml`, with tab registration
in `modules/dashboard/Content.qml` and keyboard focus routed through
`components/ScreenState.qml` and `modules/drawers/ContentWindow.qml`.

## Notification version

The pinned Quickshell revision `2d3b3e9c` still does not set the application version.
The Nix patch keeps notification server information usable by clients such as
Chrome. The patched executable is retained when `withModules` adds imageformats
and m3shapes. Remove the patch and wrapper override when the pinned source includes
the fix from [Quickshell PR 890](https://github.com/quickshell-mirror/quickshell/pull/890).

## Checks

Run `node --test tests/brightness-regression.mjs` for brightness mapping, request
ordering, range changes, discovery and idle return-action regressions. These tests
execute the QML method bodies with simulated hardware, timers and bindings.

Run `python3 tests/idle-lock-regression.py` from a Wayland session with Hyprland
and quickshell on PATH to check three lock/unlock cycles with real idle monitors.
The test locks a disposable nested compositor and replaces actions with counters.
Set `HYPRLAND` and `QUICKSHELL` to override the executable paths.

On the rebuilt desktop, verify both OSDs at 0%, 50% and 100%, rapid dragging and
brightness key repeats. Then test manual locking, activity while locked, unlocking,
and the clock and forecast layouts. Physical brightness matching and compositor idle
timing require that desktop check.

For Workspace, check the visibility toggle, previews on each monitor, arrow-key
selection, Enter and Escape, window focus, close and float actions, and dragging
between workspaces. Confirm the panel has no instruction text and horizontal
scrolling does not move Hyprland's scrolling layout. New QML files must be known
to Git for Nix flake builds to include them. `git add -N <file>` is sufficient
during development. Build with `nix build .#debug` and launch
`./result/bin/caelestia-shell` to check the packaged shell.

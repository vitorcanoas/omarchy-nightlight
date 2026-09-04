# Omarchy Night Light

Per-monitor colour temperature for Omarchy. Each screen gets its own blue-light
filter, intensity, software brightness, pause timer and schedule through one
bar widget.

## What it does

`wl-gammarelay-rs` exposes a DBus object per output. This plugin uses those
objects to warm one monitor while leaving another neutral, and stores the
chosen percentage for each screen across sessions.

The intensity scale follows Windows Night light:

```
Kelvin = 6500 - (53 x percent)      0% = 6500K neutral, 100% = 1200K deep amber
```

<img alt="Night Light in the Omarchy bar" src="preview.png" />

<img width="300" alt="The Night Light panel, one row per screen" src="panel.png" />
<img width="300" alt="The drawer, with per-screen brightness, pause and schedule" src="drawer.png" />

## Requirements

- Omarchy 4 with its Quickshell desktop (`omarchy-shell`)
- [`wl-gammarelay-rs`](https://github.com/MaxVerevkin/wl-gammarelay-rs)

`wl-gammarelay-rs` is not part of Omarchy and is not installed by this plugin:

```bash
yay -S wl-gammarelay-rs
```

### Do not run two night-light providers

Omarchy's built-in night light uses `hyprsunset`; this plugin uses
`wl-gammarelay-rs`. Both claim the Wayland `wlr-gamma-control` protocol, so
only one can control a given output. Choose one provider and keep the other
stopped. If you switch from Omarchy's night light, stop `hyprsunset` and unbind
its default key as described in [Keybindings](#keybindings).

## Install

Add and enable the plugin through Omarchy:

```bash
omarchy plugin add https://github.com/vitorcanoas/omarchy-nightlight.git --enable
```

This is sufficient for the bar widget. It calls the CLI inside the plugin by
absolute path, so the CLI does not need to be on `PATH`.

Enabling the plugin does not change the displays. The widget reads state with
`--no-start`; the daemon starts only when an action needs it, such as a switch,
slider, schedule or keybinding.

### Optional CLI installer

`install.sh` is optional. Run it only if you want to call
`omarchy-nightlight` from a terminal or from integrations that require a
command on `PATH`:

```bash
~/.config/omarchy/plugins/vitorcanoas.nightlight/install.sh
```

The script checks `wl-gammarelay-rs` and creates a symlink in
`${XDG_BIN_HOME:-$HOME/.local/bin}`. It does not start the daemon, change a
display, install the plugin or modify Omarchy configuration. The bar widget
and the absolute-path examples below do not require this script.

## Using the bar widget

| Gesture | What it does |
|---|---|
| left click | open the panel |
| right click | turn the filter on or off for all eligible screens |
| scroll | raise or lower every eligible screen by 5 points |

A screen whose saved percentage is `0` is deliberately left neutral by global
actions. A screen without a saved value uses 40% when turned on globally.

The panel has one row per screen. Each row has a switch and an intensity slider.
Dragging changes the colour live and saves once the drag ends. The `...` button
opens a drawer with software brightness, pause and schedule controls.

Keyboard controls in the panel are `j`/`k` to move between rows, `h`/`l` to
change the current value, `Space`/`Enter` to flip a switch and `Esc` to close.

## Brightness

The drawer's software brightness slider scales the compositor's gamma ramp; it
does not dim the monitor's physical backlight. Omarchy's
`omarchy-brightness-display` is preferable when a monitor supports DDC/CI, while
this control works on every output and can dim only the selected screen. The
minimum is 10%.

## Using the CLI

The optional installer is not required when using the plugin path directly:

```bash
CLI="$HOME/.config/omarchy/plugins/vitorcanoas.nightlight/bin/omarchy-nightlight"

"$CLI"                         # show every output
"$CLI" 40                      # 40% on every eligible output
"$CLI" DP-2 40                 # 40% on DP-2 only
"$CLI" DP-2 +5                 # raise DP-2 by 5 points
"$CLI" -5                      # lower every eligible output by 5 points
"$CLI" off                     # make every output neutral
"$CLI" DP-2 off                # make only DP-2 neutral
"$CLI" on                      # restore saved percentages
"$CLI" toggle                  # off if anything is on, otherwise on
"$CLI" reset                   # neutral white and full brightness everywhere
"$CLI" restore                 # re-apply saved values at login
"$CLI" --json                  # machine-readable state
"$CLI" status                  # read state without starting the daemon
"$CLI" doctor --json           # read-only installation diagnostics
"$CLI" version                 # print the plugin version

"$CLI" brightness 80           # software brightness on every output
"$CLI" DP-2 brightness 80      # software brightness on DP-2
```

Add `--no-save` to apply a change without recording it. The panel uses this
while a slider is being dragged. Use `--no-start` for read-only integrations
that must never launch the daemon, for example:

```bash
"$CLI" --json --no-start
```

`status`, `doctor` and `version` are read-only by design and never start the
daemon. `doctor --json` returns a non-zero status when a required dependency or
runtime check needs attention.

Output names are the ones printed by `hyprctl monitors` (`DP-2`, `HDMI-A-1`,
and so on). Global commands skip outputs saved at `0`; name an output
explicitly when you want to change that choice.

### Keybindings

Omarchy 4 configures Hyprland in Lua. This version uses the plugin path and
therefore does not depend on the optional installer:

```lua
local nightlight = os.getenv("HOME") .. "/.config/omarchy/plugins/vitorcanoas.nightlight/bin/omarchy-nightlight"

-- SUPER + CTRL + N is an Omarchy default for hyprsunset.
hl.unbind("SUPER + CTRL + N")

o.bind("SUPER + CTRL + MINUS", "Night light down", nightlight .. " -5")
o.bind("SUPER + CTRL + EQUAL", "Night light up", nightlight .. " +5")
o.bind("SUPER + CTRL + N", "Night light", nightlight .. " toggle")
```

If you ran `install.sh`, the commands can instead use the short
`omarchy-nightlight` name. Check your current bindings before choosing keys.

### At login

The daemon starts on demand, but saved temperatures need to be re-applied once
per session. Use the absolute plugin path so this works with the standard
Omarchy installation, where the optional installer has not been run:

```lua
local nightlight = os.getenv("HOME") .. "/.config/omarchy/plugins/vitorcanoas.nightlight/bin/omarchy-nightlight"
o.launch_on_start(nightlight .. " restore")
```

`restore` only touches outputs with a saved line in the config file, so this is
safe to keep in a configuration shared across machines.

## Pause and schedule

**Pause** turns the filter off for 15, 30 or 60 minutes and restores each
screen's own intensity automatically. **Schedule** turns the filter on and off
at two clock times; it does not calculate sunset and does not use the network.
Both controls are QML timers inside the plugin, so removing the plugin leaves
no systemd timer or cron job behind.

By default, scheduled night mode restores each screen's saved percentage. To
use one shared percentage, set `nightPercent` on the plugin's entry in
`~/.config/omarchy/shell.json` to a value above `0`. The schedule then applies
that value to outputs whose saved percentage is above `0`; outputs saved at
`0%` remain neutral because global commands intentionally skip them. Set
`nightPercent` to `0` to restore each screen's own saved percentage.

## Configuration

The backend state is stored in `~/.config/omarchy/nightlight.conf`:

```text
DP-2=40
HDMI-A-1=0
HDMI-A-1.brightness=70
```

The file stores the percentages chosen by the user, not merely the current
screen state. This is why `off` does not erase saved values and `on` can
restore them. UI settings such as `command`, `nightPercent`, schedule values
and pause state remain inline on the plugin entry in `shell.json`.

## Optional: an entry in the Omarchy menu

Menu extensions are user configuration. Add this block to
`~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"trigger.toggle.nightlight": {
  "icon": "󰔎",
  "label": "Nightlight",
  "action": "omarchy-nightlight toggle",
  "checked": "omarchy-nightlight --json --no-start | jq -e '.outputs|any(.on)'"
}
```

This example requires the optional installer and `jq`. If the installer is not
used, replace both command occurrences with the absolute plugin path. Keep
`--no-start` in the `checked` expression: menu checks run whenever the menu
opens and must not start `wl-gammarelay-rs`.

## Uninstall

Reset the outputs before removing the plugin:

```bash
~/.config/omarchy/plugins/vitorcanoas.nightlight/bin/omarchy-nightlight reset
omarchy plugin remove vitorcanoas.nightlight
```

If the plugin is already removed and a screen is still warm or dim, run
`pkill wl-gammarelay-rs` or log out. Remove optional user additions separately:

```bash
rm -f "${XDG_BIN_HOME:-$HOME/.local/bin}/omarchy-nightlight"
rm -f "$HOME/.config/omarchy/nightlight.conf"
```

Also remove any autostart line, keybindings, menu block and `shell.json` entry
you added manually. Runtime lock directories live in `XDG_RUNTIME_DIR` and
normally disappear at logout. If that variable is unavailable, the CLI creates
a private per-user directory under `/tmp`; it never uses a shared predictable
lock file.

## Troubleshooting

**The panel shows an error.** Check that `wl-gammarelay-rs` is installed and
that `hyprsunset` is not holding the output's gamma control.

**A slider moves but the screen does not change.** Stop the competing provider:
`pkill hyprsunset`.

**A screen is stuck dark or warm.** If the plugin is installed, run `reset`.
Otherwise stop `wl-gammarelay-rs` or log out.

**A screen is missing.** The panel lists outputs exposed by
`busctl --user tree rs.wl-gammarelay`. Reconnect the monitor or restart the
daemon.

**The widget does not appear.** Rescan and inspect the plugin:

```bash
omarchy-shell shell rescanPlugins
omarchy plugin list --json | jq '.[] | select(.id == "vitorcanoas.nightlight")'
```

## Development

```bash
make validate   # plugin validation, diff check and shell syntax checks
make lint       # qmllint against Omarchy's qs.Ui / qs.Commons modules
make test       # Model.js and CLI smoke tests
make dev        # sync this tree into the local plugin directory and rescan
```

`make dev` once is enough for the shell to reload plugin QML on save. The
temporary import root used by `make lint` is removed when the command finishes.
The widget is instantiated once per monitor; one instance owns the idle poll
and IPC handler while publishing state to its siblings.

## License

MIT. `wl-gammarelay-rs` is GPL-3.0-only, but it is a separate process that
communicates with this plugin over DBus; this repository does not link to or
derive code from it.

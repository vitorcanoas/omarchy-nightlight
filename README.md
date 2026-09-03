# Omarchy Night Light

A blue-light filter with an **independent intensity per monitor**, as an Omarchy
bar widget: one minimal glyph on the bar, and a panel with a switch and a
0–100% slider for every screen you have.

## Why

Omarchy's built-in night light drives `hyprsunset`, which applies one
temperature to **all** video outputs at once. There is no way to say "warm on
the monitor I read on, neutral on the one I keep for dark-mode terminals".

`wl-gammarelay-rs` is the daemon that exposes a DBus object *per output*, which
is what makes per-monitor control possible. This plugin drives it, remembers
your choice for each screen across reboots, and puts the whole thing behind one
bar icon.

The intensity scale matches the Windows "Night light" slider, so the numbers
mean what you expect:

```
Kelvin = 6500 - (53 x percent)      0% = 6500K neutral,  100% = 1200K deep amber
```

## Requirements

- Omarchy 4 with its Quickshell desktop (`omarchy-shell`)
- [`wl-gammarelay-rs`](https://github.com/MaxVerevkin/wl-gammarelay-rs) — `yay -S wl-gammarelay-rs`

> **hyprsunset must not be running.** `hyprsunset` and `wl-gammarelay-rs` both
> claim the Wayland `wlr-gamma-control` protocol, which allows a single client
> per output. If both run, whichever lost the race silently does nothing. Take
> `hyprsunset` out of your autostart and `pkill hyprsunset` before using this.

## Install

```bash
omarchy plugin add https://github.com/vitorcanoas/omarchy-nightlight.git --enable
```

That is all the bar widget needs — it calls the CLI inside the plugin folder by
absolute path, so nothing has to be on your `PATH`.

If you also want the command in a terminal or bound to a key, run the optional
installer once. It symlinks the CLI into `~/.local/bin` and checks the
dependency:

```bash
~/.config/omarchy/plugins/vitorcanoas.nightlight/install.sh
```

## Using the bar widget

| Gesture | What it does |
|---|---|
| left click | open the panel |
| right click | turn the filter on everywhere it is saved, or off everywhere |
| scroll | raise/lower every screen by 5 points |

In the panel, each screen gets its own row: a switch to turn that screen's
filter on or off, and a slider for its intensity. **All** and **None** act on
every screen at once. Dragging a slider previews immediately and writes once the
gesture settles, so a drag never floods the machine with processes.

Keyboard: `j`/`k` move between rows, `h`/`l` change the intensity of the row you
are on, `Space`/`Enter` flip a switch, `Esc` closes.

## Using the CLI

```bash
omarchy-nightlight                 # show the state of every output
omarchy-nightlight 40              # 40% on every output
omarchy-nightlight DP-2 40         # 40% on DP-2 only
omarchy-nightlight DP-2 +5         # raise DP-2 by 5 points
omarchy-nightlight -5              # lower every output by 5 points
omarchy-nightlight off             # everything neutral
omarchy-nightlight DP-2 off        # only DP-2 neutral
omarchy-nightlight on              # restore the saved percentages
omarchy-nightlight toggle          # off if anything is on, else on
omarchy-nightlight restore         # re-apply the saved file (use at login)
omarchy-nightlight --json          # machine-readable state
```

Output names are the ones `hyprctl monitors` prints (`DP-2`, `HDMI-A-1`, …).

### Keybindings

Add to `~/.config/hypr/bindings.conf` (or `bindings.lua` on Omarchy 4):

```
bindd = SUPER CTRL, minus, Night light down, exec, omarchy-nightlight -5
bindd = SUPER CTRL, equal, Night light up,   exec, omarchy-nightlight +5
bindd = SUPER CTRL, N,     Night light,      exec, omarchy-nightlight toggle
```

### At login

The daemon starts on demand, but the saved temperatures need re-applying once
per session. Add this to your autostart:

```
omarchy-nightlight restore
```

`restore` only touches outputs that have a line in the config file, so the same
autostart is safe to version across machines that never configured night light.

## Configuration

`~/.config/omarchy/nightlight.conf`, one `output=percent` line per screen:

```
DP-2=40
HDMI-A-1=0
```

It stores the percentage you **chose**, not what is currently on screen — which
is why `off` erases nothing and `on` can bring everything back.

**A screen saved at `0` is deliberately neutral.** Global commands
(`omarchy-nightlight on`, `+5`, the scroll gesture, the **All** button) skip it,
so a portrait monitor you keep clean stays clean. Naming the output explicitly
(`omarchy-nightlight HDMI-A-1 30`, or its slider in the panel) still works —
that is how you change your mind.

## Uninstall

```bash
omarchy plugin remove vitorcanoas.nightlight
rm -f ~/.local/bin/omarchy-nightlight        # only if you ran install.sh
```

Screens are left at whatever temperature they were on; run
`omarchy-nightlight off` first if you want them neutral. The config file is left
in place.

## Troubleshooting

**The panel shows an error line.** That is the CLI's own stderr. The usual
causes are `wl-gammarelay-rs` not being installed, or `hyprsunset` holding the
outputs.

**A slider moves but the screen does not change.** Something else already owns
gamma control for that output — almost always `hyprsunset`. `pkill hyprsunset`.

**A screen is missing from the panel.** The list comes from
`busctl --user tree rs.wl-gammarelay`, which only shows outputs the daemon has
bound. Reconnect the monitor, or restart the daemon.

**The widget does not appear after installing.**

```bash
omarchy-shell shell rescanPlugins
omarchy plugin list --json | jq '.[] | select(.id == "vitorcanoas.nightlight")'
```

## Development

```bash
make validate   # omarchy plugin validate + shell syntax checks
make dev        # rsync this tree into ~/.config/omarchy/plugins and rescan
```

The shell reloads plugin QML on save, so `make dev` once and then just edit.

## License

MIT

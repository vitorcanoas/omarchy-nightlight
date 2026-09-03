# Omarchy Night Light

**Per-monitor colour temperature.** A separate blue-light filter, with its own
intensity, for every screen — as an Omarchy bar widget: one minimal glyph on the
bar, and a panel with a switch and a 0–100% slider per screen.

## Why

Every other night-light option for Omarchy — the built-in one included — drives
`hyprsunset` or `sunsetr`, and both apply a single temperature to **all** video
outputs at once. There is no way to say "warm on the monitor I read on, neutral
on the one I keep for dark-mode terminals".

That is the gap this fills. `wl-gammarelay-rs` exposes a DBus object *per
output*, which is what makes per-monitor temperature possible at all. This
plugin drives it, remembers your choice for each screen across reboots, and puts
the whole thing behind one bar icon.

<img alt="Night Light in the Omarchy bar" src="preview.png" />

<img width="300" alt="The Night Light panel, one row per screen" src="panel.png" />
<img width="300" alt="The drawer, with per-screen brightness, pause and schedule" src="drawer.png" />

The intensity scale matches the Windows "Night light" slider, so the numbers
mean what you expect:

```
Kelvin = 6500 - (53 x percent)      0% = 6500K neutral,  100% = 1200K deep amber
```

## Requirements

- Omarchy 4 with its Quickshell desktop (`omarchy-shell`)
- [`wl-gammarelay-rs`](https://github.com/MaxVerevkin/wl-gammarelay-rs)

`wl-gammarelay-rs` is **not** part of Omarchy and is not pulled in by installing
this plugin — Omarchy never runs anything from a plugin folder. Install it
yourself from the AUR:

```bash
yay -S wl-gammarelay-rs
```

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

**Installing it does not change your screens.** The widget reads with
`--no-start`, so simply enabling it never launches `wl-gammarelay-rs` and never
takes the Wayland gamma control away from whatever already holds it. The daemon
starts the first time you actually ask for something — a switch, a slider, a
keybinding. Until then the panel just tells you it is not running.

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
filter on or off, and a slider for its intensity. Dragging a slider changes the
colour live and saves once you let go, so a drag never floods the machine with
processes or records the values you merely passed through.

The `⋯` button beside the master switch opens a drawer with per-screen
brightness, pause, and the schedule. It closes again every time you open the
panel, so the default view stays the list of screens.

Keyboard: `j`/`k` move between rows, `h`/`l` change the value of the row you are
on, `Space`/`Enter` flip a switch, `Esc` closes. The drawer's own controls are
mouse-driven.

## Brightness

Each screen also gets a **software brightness** slider, in the panel's drawer
(the `⋯` button next to the master switch).

This is not a repackaging of Omarchy's own brightness control, and it is worth
knowing why both exist:

|  | Omarchy's `omarchy-brightness-display` | this plugin |
|---|---|---|
| How | the monitor's own backlight, over DDC/CI | the compositor's gamma ramp |
| Works on | monitors that answer DDC — many desktop monitors do not | every output, always |
| Real light output | yes, genuinely dimmer backlight | no, the image is scaled darker |

So use Omarchy's when your monitor supports it: dimming the actual backlight is
better for your eyes and for power. Use this one for the screen that ignores
DDC entirely, which is the common case for a second monitor — dimming one panel
at night without touching the other is the whole reason it is here.

The floor is 10%. `wl-gammarelay-rs` allows lower, but a screen at 2% is
unreadable and the only way back would be the CLI.

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
omarchy-nightlight reset           # neutral white and full brightness, everywhere
omarchy-nightlight restore         # re-apply the saved file (use at login)
omarchy-nightlight --json          # machine-readable state

omarchy-nightlight brightness 80        # software brightness, every screen
omarchy-nightlight DP-2 brightness 80   # software brightness on DP-2 only
```

Add `--no-save` to any of these to apply it without recording it — that is what
the panel uses while a slider is being dragged.

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

## Pause and schedule

Both live in the drawer behind the `⋯` button, so the panel you see when you
click the bar icon stays the list of screens and nothing else.

**Pause** turns the filter off for 15, 30 or 60 minutes and brings it back by
itself — for editing photos or video, where a warm screen lies to you about
colour. Each screen returns to its own intensity, because pausing goes through
`off`/`on`, which never rewrite what you saved.

**Schedule** is off by default and turns the filter on and off at two times you
type. It schedules *on and off*, not an intensity, so every screen keeps its own
percentage and a screen set to 0% stays neutral. It is clock-only: no location,
no sunset calculation, no network.

The countdown and the schedule are plain QML timers inside the plugin. They are
deliberately not systemd timers or cron entries: Omarchy runs nothing when a
plugin is removed, so anything registered outside this folder would outlive the
uninstall forever.

<details>
<summary>Forcing one shared intensity at night</summary>

Set `nightPercent` on the plugin's entry in `shell.json` to a number above 0 and
the schedule will apply that percentage to every screen instead of restoring
each screen's own. It has no UI because a single global intensity is the
opposite of what most people install this for.

</details>

## Configuration

`~/.config/omarchy/nightlight.conf`, one `output=percent` line per screen:

```
DP-2=40
HDMI-A-1=0
```

It stores the percentage you **chose**, not what is currently on screen — which
is why `off` erases nothing and `on` can bring everything back.

<details>
<summary>Why a file instead of inline settings in <code>shell.json</code></summary>

Omarchy's rule is that plugin settings live inline on the bar entry in
`shell.json`, and this plugin follows it for everything that is a setting: the
one option it has (`command`) is read with `setting()` from that entry.

The saved percentages are not a setting, they are backend state, and they have
to survive the shell being down. `omarchy-nightlight restore` runs at login
before the bar exists, and a keybinding or an SSH session has to reach the same
values without Quickshell running at all. A file both sides can read is the only
thing that satisfies that; parsing `shell.json` from bash would make the CLI
depend on the very component it has to work without.

</details>

**A screen saved at `0` is deliberately neutral.** Global commands
(`omarchy-nightlight on`, `+5`, the scroll gesture, the **All** button) skip it,
so a portrait monitor you keep clean stays clean. Naming the output explicitly
(`omarchy-nightlight HDMI-A-1 30`, or its slider in the panel) still works —
that is how you change your mind.

## Optional: an entry in the Omarchy menu

Omarchy only reads menu extensions from *your* config, never from a plugin
folder, so this is a manual paste — which also means it does not disappear when
the plugin does. Add to `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"trigger.toggle.nightlight": {
  "icon": "󰔎",
  "label": "Nightlight",
  "action": "omarchy-nightlight toggle",
  "checked": "omarchy-nightlight --json | jq -e '.outputs|any(.on)'"
}
```

Needs `omarchy-nightlight` on your `PATH` (see the optional installer above) and
`jq` for the `checked` expression. Remove the block by hand if you uninstall.

## Licensing

This plugin is MIT. `wl-gammarelay-rs` is GPL-3.0-only, which does **not** reach
this code: the two are separate processes talking over DBus, and IPC between
separate programs is not linking. Nothing here is derived from its source.

## Uninstall

**Put your screens back first.** Removing the plugin deletes the CLI along with
it, and `wl-gammarelay-rs` keeps applying whatever ramp it was last given — a
dimmed or warm screen with nothing left on disk to explain it or undo it.

```bash
~/.config/omarchy/plugins/vitorcanoas.nightlight/bin/omarchy-nightlight reset
omarchy plugin remove vitorcanoas.nightlight
```

The full path matters: `install.sh` is optional, so on a default install
`omarchy-nightlight` is not on your `PATH`.

If you already removed the plugin and a screen is stuck, either of these fixes
it — the ramp is only held while the daemon is alive:

```bash
pkill wl-gammarelay-rs
```

or just log out and back in. The daemon runs inside the Hyprland session scope,
so it dies with the session and the screens come back on their own.

`omarchy plugin remove` only deletes the plugin folder — it never runs anything
from the plugin. Whatever you added by hand is still yours to remove:

```bash
rm -f ~/.local/bin/omarchy-nightlight        # only if you ran install.sh
rm -f ~/.config/omarchy/nightlight.conf      # your saved percentages
```

Also check, if you set them up:

- the `omarchy-nightlight restore` line in your autostart — left behind it
  points at a dead symlink and fails quietly at every login
- any keybindings in `~/.config/hypr/bindings.conf` (or `bindings.lua`)
- the menu block in `~/.config/omarchy/extensions/omarchy-menu.jsonc`
- the widget's entry in `~/.config/omarchy/shell.json`, including any
  `scheduleEnabled` / `scheduleOnAt` / `scheduleOffAt` / `pausedUntil` settings
  the panel saved onto it

## Troubleshooting

**The panel shows an error line.** That is the CLI's own stderr. The usual
causes are `wl-gammarelay-rs` not being installed, or `hyprsunset` holding the
outputs.

**A slider moves but the screen does not change.** Something else already owns
gamma control for that output — almost always `hyprsunset`. `pkill hyprsunset`.

**A screen is stuck dark or warm and the plugin is gone.** The daemon is still
applying the last ramp it was given. `pkill wl-gammarelay-rs`, or log out — it
dies with the session. If the plugin is still installed, `omarchy-nightlight
reset` is the tidy way.

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
make validate   # omarchy plugin validate, git diff --check, shell syntax checks
make lint       # qmllint against the real qs.Ui / qs.Commons modules
make dev        # rsync this tree into ~/.config/omarchy/plugins and rescan
```

The shell reloads plugin QML on save, so `make dev` once and then just edit.

`make lint` builds a temporary import root because `qmllint -I` needs a
directory *containing* `qs`, not the shell directory itself. The remaining
`unqualified` and `missing-property` warnings are the same ones Omarchy's own
first-party panels produce — `bar` is typed `QtObject`, so its members are
invisible to static analysis.

A bar widget is instantiated **once per monitor**, so this plugin elects a
single owner for the idle poll and publishes the result to its siblings; only
that owner registers the IPC handler. Keep that in mind before adding anything
that shells out.

## License

MIT

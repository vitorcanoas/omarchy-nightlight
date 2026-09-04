# Omarchy Night Light

Per-monitor night light for [Omarchy](https://omarchy.org): choose a different
colour temperature and software brightness for every screen.

Built for desks with more than one monitor and long sessions: Omarchy's
built-in night light applies one setting to every display. This plugin lets
you choose a comfortable colour temperature and software brightness for each
screen, so one monitor can be warm while another stays neutral.

## Install

You need Omarchy 4 and [`wl-gammarelay-rs`](https://github.com/MaxVerevkin/wl-gammarelay-rs):

```bash
omarchy pkg aur add wl-gammarelay-rs
omarchy plugin add https://github.com/vitorcanoas/omarchy-nightlight.git --enable
```

The plugin also uses Python 3 and standard system utilities already present on
Omarchy for bounded, atomic configuration persistence.

Omarchy is Arch-based. If you prefer, `yay -S wl-gammarelay-rs` does the same
thing.

After enabling the plugin, look for the Night Light icon in the Omarchy bar and
left click it to open the panel. Use the switch and slider for each screen. The
installation does not change your display until you choose an intensity. Right
click toggles all eligible screens; scrolling changes their intensity by 5
points.

<p align="center">
  <img width="360" src="panel.png" alt="Night Light panel" />
</p>

> **Using Omarchy's built-in night light?** Disable it before using this
> plugin. Both it and `hyprsunset` control the same display setting. Running
> `pkill hyprsunset` is useful for a quick test, but disable the built-in night
> light in Omarchy as well — do not use `omarchy toggle nightlight` — so it
> does not return after the next login.

## Quick commands

The widget works without installing a command on `PATH`. For terminal use:

```bash
CLI="$HOME/.config/omarchy/plugins/vitorcanoas.nightlight/bin/omarchy-nightlight"

"$CLI" status
"$CLI" 40          # set every eligible screen to 40%
"$CLI" DP-2 +5     # increase one screen
"$CLI" off         # turn the filter off
"$CLI" doctor      # check the installation
```

If the icon does not appear or a display does not respond, run `"$CLI" doctor`
first. It reports missing requirements and common setup problems.

`install.sh` is optional; it only creates a convenient `omarchy-nightlight`
command on `PATH`. It does not install the plugin or start the daemon.

## Uninstall

```bash
"$HOME/.config/omarchy/plugins/vitorcanoas.nightlight/bin/omarchy-nightlight" reset
omarchy plugin remove vitorcanoas.nightlight
```

## More information

- [Complete guide](docs/guide.md) — CLI, keybindings, schedules, brightness,
  configuration, troubleshooting and development
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Changelog](CHANGELOG.md)

## License

MIT.

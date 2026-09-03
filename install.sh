#!/bin/bash
# OPTIONAL AND MANUAL. Nothing runs this for you: Omarchy has no install hook,
# and `omarchy plugin remove` runs nothing either. The bar widget works fully
# without it, because it calls the CLI inside the plugin folder by absolute
# path.
#
# Run it only if you also want `omarchy-nightlight` on your PATH, for a terminal
# or a Hyprland keybinding. It creates ONE symlink in ~/.local/bin.
#
# That symlink is the only thing this plugin ever puts outside its own folder,
# and removing the plugin will NOT take it with them. Undo it by hand:
#
#     rm -f ~/.local/bin/omarchy-nightlight

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
LINK="$BIN_DIR/omarchy-nightlight"

if ! command -v wl-gammarelay-rs >/dev/null 2>&1; then
  cat >&2 <<'MSG'
wl-gammarelay-rs is not installed. It is what exposes a DBus object per Wayland
output, which is the only way to filter one monitor and not another.

    yay -S wl-gammarelay-rs

MSG
  exit 1
fi

# hyprsunset and wl-gammarelay-rs both claim the Wayland gamma-control
# protocol, which allows one client per output. Running both leaves whichever
# lost the race silently doing nothing, so say it now rather than let someone
# debug it later.
if pgrep -x hyprsunset >/dev/null 2>&1; then
  cat >&2 <<'MSG'
Warning: hyprsunset is running. It and wl-gammarelay-rs cannot share the same
outputs. Remove hyprsunset from your autostart and stop it:

    pkill hyprsunset

MSG
fi

mkdir -p "$BIN_DIR"
ln -sfn "$HERE/bin/omarchy-nightlight" "$LINK"
printf 'linked %s -> %s\n' "$LINK" "$HERE/bin/omarchy-nightlight"
printf 'remove it later with: rm -f %s\n' "$LINK"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf 'note: %s is not on your PATH\n' "$BIN_DIR" >&2 ;;
esac

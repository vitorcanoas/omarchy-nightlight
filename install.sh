#!/bin/bash
# Optional. The bar widget already works without this: it calls the CLI inside
# the plugin folder by absolute path, so `omarchy plugin add` is all you need.
#
# Run this only if you also want `omarchy-nightlight` on your PATH, for a
# terminal or for a Hyprland keybinding. It symlinks the CLI into ~/.local/bin
# and checks the one dependency.

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

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf 'note: %s is not on your PATH\n' "$BIN_DIR" >&2 ;;
esac

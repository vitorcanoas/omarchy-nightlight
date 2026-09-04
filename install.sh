#!/bin/bash
# OPTIONAL AND MANUAL. Nothing runs this for you: Omarchy has no install hook,
# and `omarchy plugin remove` runs nothing either. The bar widget works fully
# without it, because it calls the CLI inside the plugin folder by absolute
# path.
#
# Run it only if you also want `omarchy-nightlight` on your PATH, for a terminal
# or a Hyprland keybinding. It creates ONE symlink in ~/.local/bin.
#
# That symlink is the only thing THIS SCRIPT puts outside the plugin folder, and
# removing the plugin will NOT take it with it. Undo it by hand:
#
#     rm -f ~/.local/bin/omarchy-nightlight
#
# The plugin itself also writes ~/.config/omarchy/nightlight.conf (your saved
# percentages) and two short-lived private lock directories under
# $XDG_RUNTIME_DIR. The README's Uninstall section lists all of it.

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

# Refuse to overwrite anything that is not already our own symlink. The name is
# generic enough to collide -- Omarchy itself ships `omarchy-toggle-nightlight`
# -- and `ln -sfn` replaces a regular file without a word. Losing someone's own
# script to an optional convenience step, with an uninstall that then `rm`s the
# remains rather than restoring them, is not a trade this script gets to make.
if [[ -e $LINK || -L $LINK ]]; then
  if [[ -L $LINK && $(readlink -f "$LINK") == "$(readlink -f "$HERE/bin/omarchy-nightlight")" ]]; then
    printf 'already linked: %s\n' "$LINK"
    exit 0
  fi

  # A dangling symlink of our own name is almost always this installer's work
  # from somewhere else -- run once from a git clone that has since been
  # deleted, or from a previous plugin folder. Treated as a foreign file it
  # produced the worst possible outcome: "refusing to replace it" about a dead
  # link that nothing else would ever repair, and a broken command left on PATH.
  # Say what it is and offer the one-line fix rather than stopping flat.
  if [[ -L $LINK && ! -e $LINK ]]; then
    cat >&2 <<MSG
$LINK is a broken symlink, pointing at:

    $(readlink "$LINK")

That target no longer exists -- most likely this installer was run from a copy
of the plugin that has since been deleted. Nothing else will repair it, so it is
yours to clear before linking again:

    rm -f "$LINK" && "$HERE/install.sh"

MSG
    exit 1
  fi

  cat >&2 <<MSG
$LINK already exists and is not this plugin's symlink.

Refusing to replace it. Move it aside first, or link this plugin under another
name if you would rather keep both:

    ln -s "$HERE/bin/omarchy-nightlight" "$BIN_DIR/some-other-name"

MSG
  exit 1
fi

ln -s "$HERE/bin/omarchy-nightlight" "$LINK"
printf 'linked %s -> %s\n' "$LINK" "$HERE/bin/omarchy-nightlight"
printf 'remove it later with: rm -f %s\n' "$LINK"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf 'note: %s is not on your PATH\n' "$BIN_DIR" >&2 ;;
esac

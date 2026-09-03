// Pure translation between what `bin/omarchy-nightlight --json` prints and the
// state the widget draws. Kept out of the QML for the same reason the
// first-party panels keep a Model.js (panels/audio, panels/monitor): logic that
// depends on nothing from Quickshell is logic you can reason about on its own.
//
// The CLI contract, one entry per Wayland output:
//   {"outputs":[{"name":"DP-2","percent":40,"kelvin":4380,"on":true,"saved":40},
//               {"name":"HDMI-A-1","percent":0,"kelvin":6500,"on":false,"saved":0}]}
//
// `name` is the Hyprland output name, `percent` is the current intensity (0
// while off), `saved` is the percentage `on` returns to. Nothing here may
// assume how many outputs exist or what they are called: the list is always
// whatever the CLI reported. People run one screen; people also run five.

// Mirrors DEFAULT in bin/omarchy-nightlight. This is the only number shared
// between the shell script and the QML, and it exists for exactly one case: an
// output saved at 0% is deliberately neutral, so `toggle` on it would re-apply
// 0% and the switch would look broken. In that one case the widget sends an
// explicit percentage instead.
var DEFAULT_PERCENT = 40

function clampPercent(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 0
  if (n < 0) return 0
  if (n > 100) return 100
  return n
}

// Returns { names: [...], byName: { name: {...} } }, or null when the output is
// unusable (CLI missing, daemon down, truncated JSON). Returning null rather
// than an empty object is what lets the widget tell "off" apart from "I do not
// know yet" — showing 0% without knowing would be a lie, and the user would
// start dragging the slider from a position that was never real.
function parseState(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (text === "") return null

  var payload
  try {
    payload = JSON.parse(text)
  } catch (error) {
    return null
  }

  if (!payload || !Array.isArray(payload.outputs)) return null

  var names = []
  var byName = {}
  for (var i = 0; i < payload.outputs.length; i++) {
    var entry = payload.outputs[i]
    if (!entry || typeof entry.name !== "string" || entry.name === "") continue
    names.push(entry.name)
    byName[entry.name] = {
      name: entry.name,
      percent: clampPercent(entry.percent),
      kelvin: Number(entry.kelvin) || 0,
      on: entry.on === true,
      saved: clampPercent(entry.saved)
    }
  }

  if (names.length === 0) return null
  return { names: names, byName: byName }
}

// Used to reassign the Repeater's model only when the SET of outputs actually
// changes. Reassigning it on every poll would destroy and rebuild the delegates,
// and a slider rebuilt mid-drag loses the drag.
function signature(names) {
  return names.join(" ")
}

function countOn(names, isOn) {
  var n = 0
  for (var i = 0; i < names.length; i++) if (isOn(names[i])) n++
  return n
}

function summary(loaded, total, on) {
  if (!loaded) return "Reading state"
  if (total === 0) return "No screens"
  if (on === 0) return "Off"
  if (on === total) return total === 1 ? "On" : "On for all " + total + " screens"
  return on + " of " + total + " screens"
}

// The stderr of a failed run, trimmed to something a one-line panel row can
// carry without pushing the rest of the panel off screen.
function clampMessage(raw, limit) {
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (text === "") return ""
  text = text.split("\n")[0].trim()
  var max = limit === undefined ? 160 : limit
  return text.length > max ? text.substring(0, max - 1) + "…" : text
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_PERCENT: DEFAULT_PERCENT,
    clampPercent: clampPercent,
    parseState: parseState,
    signature: signature,
    countOn: countOn,
    summary: summary,
    clampMessage: clampMessage
  }
}

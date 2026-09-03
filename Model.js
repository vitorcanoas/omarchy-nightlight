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

// wl-gammarelay-rs takes 0.1-1.0; below that the screen is unreadable and the
// only way back is the CLI, so the floor is part of the contract, not a taste.
var BRIGHTNESS_MIN = 10

function clampBrightness(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 100
  if (n < BRIGHTNESS_MIN) return BRIGHTNESS_MIN
  if (n > 100) return 100
  return n
}

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
      saved: clampPercent(entry.saved),
      // Software brightness, 10-100. Absent in an older CLI, so default to full
      // rather than to zero, which would draw every slider at the bottom and
      // invite someone to "fix" it by dragging.
      brightness: entry.brightness === undefined ? 100 : clampBrightness(entry.brightness)
    }
  }

  // An empty list is a real answer, not a parse failure: the CLI reports it
  // with a warning explaining why (no daemon, or nothing bound because another
  // client holds the gamma control). Returning null here made that case
  // indistinguishable from unreadable output, so the panel kept stale values
  // and said nothing.
  if (names.length === 0 && !payload.warning) return null
  // `warning` is advisory, not an error: the CLI still worked. Today the only
  // one is hyprsunset holding the outputs, which makes every command appear to
  // do nothing at all -- the single most confusing way this can fail.
  return { names: names, byName: byName, warning: String(payload.warning || "") }
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

// ---- schedule -------------------------------------------------------------
// "HH:MM" -> minutes since midnight, or -1 when it is not a valid time. Kept
// strict on purpose: a typo in a time field should leave the schedule inert
// rather than guess a boundary and darken someone's screen at random.
function parseTime(value) {
  var match = String(value === undefined || value === null ? "" : value).trim().match(/^(\d{1,2}):(\d{2})$/)
  if (!match) return -1
  var hours = Number(match[1])
  var minutes = Number(match[2])
  if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59) return -1
  return hours * 60 + minutes
}

function formatTime(minutes) {
  var m = Math.max(0, Math.min(24 * 60 - 1, Math.round(Number(minutes) || 0)))
  var hh = Math.floor(m / 60)
  var mm = m % 60
  return (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm
}

// Which side of the schedule `date` falls on: "night" between onAt and offAt,
// "day" otherwise, "" when either time is unusable. The window normally wraps
// midnight (on at 20:00, off at 07:00), so the comparison has to handle both
// the wrapping and the non-wrapping case rather than assuming on < off.
function phaseAt(date, onAt, offAt) {
  var on = parseTime(onAt)
  var off = parseTime(offAt)
  if (on < 0 || off < 0 || on === off) return ""
  var now = date.getHours() * 60 + date.getMinutes()
  var isNight = on < off ? (now >= on && now < off) : (now >= on || now < off)
  return isNight ? "night" : "day"
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_PERCENT: DEFAULT_PERCENT,
    clampPercent: clampPercent,
    clampBrightness: clampBrightness,
    BRIGHTNESS_MIN: BRIGHTNESS_MIN,
    parseState: parseState,
    signature: signature,
    countOn: countOn,
    summary: summary,
    clampMessage: clampMessage,
    parseTime: parseTime,
    formatTime: formatTime,
    phaseAt: phaseAt
  }
}

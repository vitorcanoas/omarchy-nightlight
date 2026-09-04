import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Night Light bar widget: one minimal glyph on the bar, and a panel on click
// with a row per screen — its own switch and its own intensity slider.
//
// Why `Panel` (qs.Ui) rather than `BarWidget`: Panel already owns the
// open/close lifecycle and the IpcHandler that omarchy.audio, omarchy.monitor
// and omarchy.bluetooth all use. Nothing here is invented; the structure
// follows the first-party brightness panel, because the problem is the same —
// sliders driving an external process without blocking the UI.
//
// Why this plugin ships its own CLI instead of talking to the backend from
// QML: the percentage↔Kelvin scale, the per-output DBus paths and the saved
// file are one policy, and it has to behave identically whether it is a
// keybinding, a script or this panel doing the asking. Keeping it in
// bin/omarchy-nightlight means the widget can never drift from the shortcut,
// and a user who prefers the terminal gets the same semantics for free.
//
// Why not the first-party `omarchy.nightlight` service: it reads and writes
// `hyprctl hyprsunset temperature`, knows exactly two states, and has no
// concept of an output. That is the whole limitation this plugin exists to
// remove.
Panel {
  id: root
  moduleName: "vitorcanoas.nightlight"
  // A bar surface exists per monitor, so this widget is live once per screen
  // even though it appears once in the layout, and an IPC target routes to
  // exactly one handler. `manageIpc: false` stands the base class's handler
  // down so the one below owns the target; the base declares its handler
  // `enabled: manageIpc && ipcTarget !== ""`, so either half alone would do it.
  //
  // The remaining "registered but will not be used" warning is the sibling
  // instances losing the race for the same target, which is exactly what
  // omarchy.monitor and omarchy.tailscale do too. Whichever wins relays to the
  // others through peers().
  manageIpc: false
  ipcTarget: "vitorcanoas.nightlight"

  // The CLI lives in this plugin's own directory, so the plugin works straight
  // after `omarchy plugin add` with nothing on PATH. install.sh only adds a
  // convenience symlink for people who also want it in a terminal or a
  // keybinding.
  readonly property string sourceDir: localPath(Qt.resolvedUrl("."))
  readonly property string command: setting("command", sourceDir + "/bin/omarchy-nightlight")

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    while (value.length > 1 && value.charAt(value.length - 1) === "/")
      value = value.substring(0, value.length - 1)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  // ---- state mirrored from the CLI ---------------------------------------
  // `names` is the Repeater's model and is only reassigned when the SET of
  // outputs changes; `byName` changes on every read. Splitting the two is what
  // keeps a routine poll from rebuilding the delegates and dropping a drag in
  // progress (the first-party audio panel documents the same hazard).
  property var names: []
  property var byName: ({})

  // Optimistic overlay, name -> { percent, on }. The slider and the switch move
  // at once and this layer holds the value until the CLI confirms, otherwise
  // the UI would jump backwards on the next read.
  property var pending: ({})

  property bool stateLoaded: false
  property string errorText: ""
  // Advisory, unlike errorText: the command worked, but something about the
  // system will make it look like it did not.
  property string warningText: ""

  // Name of the output being dragged, and the one the debounce will write.
  property string draggingName: ""
  property string debouncedName: ""
  // Which slider the pending debounce belongs to, so one timer serves both.
  property bool debouncedBrightness: false

  // Carries sub-notch wheel deltas between events; same trick the first-party
  // audio widget uses so a touchpad scroll is not swallowed.
  property real wheelAccumulator: 0

  // Theme handles, named the way the first-party panels name them so the rest
  // of this file reads like theirs. Nothing is ever a literal colour: the bar
  // hands down the active theme's foreground and the panel derives from it.
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- queries ------------------------------------------------------------
  function infoFor(name) {
    var local = root.pending[name]
    if (local) return local
    var known = root.byName[name]
    return known ? known : { percent: 0, on: false, saved: 0 }
  }

  function percentFor(name) { return Model.clampPercent(infoFor(name).percent) }
  function brightnessFor(name) {
    var local = root.pending[name]
    if (local && local.brightness !== undefined) return Model.clampBrightness(local.brightness)
    var known = root.byName[name]
    return known ? Model.clampBrightness(known.brightness) : 100
  }
  function isOn(name) { return infoFor(name).on === true }
  function savedFor(name) {
    var known = root.byName[name]
    return known ? Model.clampPercent(known.saved) : 0
  }

  readonly property int screenCount: names.length
  readonly property int screensOn: Model.countOn(names, function(n) { return root.isOn(n) })
  // The bar glyph lights up when ANY screen is filtered, so a monitor left on
  // stays visible instead of hiding behind an average.
  readonly property bool anyOn: screensOn > 0
  readonly property string summary: Model.summary(stateLoaded, screenCount, screensOn)
  // True only when we have actually heard back and there is nothing to show.
  readonly property bool noScreens: stateLoaded && screenCount === 0

  // ---- the sibling instances ----------------------------------------------
  // Every screen gets its own copy of this widget. They must agree on state,
  // and they must not each shell out for it: five monitors would otherwise mean
  // five `--json` processes on every poll, forever.
  function peers() {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : []
    return items.length > 0 ? items : [root]
  }

  // The first live instance owns the idle poll. Resolved at call time rather
  // than cached, because bar surfaces come and go when a monitor is plugged in
  // and the answer has to survive that on its own.
  function isPollOwner() {
    var items = peers()
    return items.length === 0 || items[0] === root
  }

  // One read, N widgets updated. Called by whichever instance actually ran the
  // CLI, including itself.
  function publishState(names, byName, warning) {
    var items = peers()
    for (var i = 0; i < items.length; i++) {
      var peer = items[i]
      if (peer && typeof peer.adoptState === "function") peer.adoptState(names, byName, warning)
    }
  }

  // A write on ANY instance invalidates a read in flight on any other: the
  // reader publishes its result to every peer, so a per-instance epoch left the
  // whole bug alive on a two-monitor machine -- the owner's background poll
  // would happily overwrite a switch the user had just flipped on the other
  // screen. Bumped the same way pauses and schedule phases are.
  function publishWrite() {
    var items = peers()
    for (var i = 0; i < items.length; i++) {
      var peer = items[i]
      if (peer && typeof peer.adoptWrite === "function") peer.adoptWrite()
    }
  }

  function adoptWrite() { root.stateEpoch++ }

  function publishError(message) {
    var items = peers()
    for (var i = 0; i < items.length; i++) {
      var peer = items[i]
      if (peer && typeof peer.adoptError === "function") peer.adoptError(message)
    }
  }

  function adoptState(names, byName, warning) {
    // Nothing is adopted mid-gesture, the output list least of all. The
    // Repeater's model is a JS array, so reassigning it rebuilds every delegate
    // -- including the slider under the user's finger. A destroyed slider never
    // emits onDraggingChanged, so `draggingName` would stay set forever, `busy`
    // with it, and this function would early-return for the rest of the shell's
    // life. The CLI could set that off by itself: a busctl hiccup used to drop
    // an output for a single poll and flip the signature.
    if (root.busy) return

    // A daemon that is not running is not the same as a machine with no
    // screens. With --no-start the poll reports zero outputs plus a warning,
    // and wiping the list on that left the panel stuck at "No screens" with
    // nothing left to click -- the poll used to heal itself by starting the
    // daemon, and deliberately no longer does. Keep the last known screens and
    // let the warning do the explaining.
    if (names.length === 0 && String(warning || "") !== "" && root.names.length > 0) {
      root.stateLoaded = true
      root.errorText = ""
      root.warningText = String(warning)
      return
    }

    // The output list applies whenever it really changed -- a monitor plugged
    // or unplugged -- and only then, so the delegates stay put otherwise.
    if (Model.signature(names) !== Model.signature(root.names)) {
      root.names = names
      root.cursorIndex = Math.min(root.cursorIndex, Math.max(0, names.length * 3))
    }

    root.byName = byName
    root.pending = ({})
    root.stateLoaded = true
    root.errorText = ""
    root.warningText = String(warning || "")
  }


  function adoptError(message) {
    root.stateLoaded = false
    root.errorText = message
    // Drop the optimistic values with it. They describe what the user asked
    // for, and the request is what just failed -- keeping them would leave the
    // panel showing a state no screen is in.
    root.pending = ({})
  }

  // ---- reading ------------------------------------------------------------
  //
  // `stateEpoch` ties a read's result to the world it was started in. Every
  // write bumps it; a read carries the value it saw at launch and its result is
  // discarded if the epoch moved while it was in flight. Without that, a poll
  // that started 50ms BEFORE the user flipped a switch came back 200ms after
  // the apply had finished, `busy` was false again, and adoptState installed
  // the pre-toggle state -- the switch visibly flipped itself back, and stayed
  // wrong until the next poll: 2s with the panel open, up to 20s with it shut.
  property int stateEpoch: 0
  property int stateReadEpoch: -1

  // A refresh asked for while a read is already running used to be dropped
  // outright, which is exactly what swallowed the confirming refresh after an
  // apply. Remember it and run it as soon as the current read lands.
  property bool refreshQueued: false

  // A successful process exit is not enough to trust the state payload. Keep
  // this until both Process.exited and streamFinished have landed, because
  // Quickshell does not guarantee their order.
  property bool statePayloadInvalid: false
  property int stateExitCode: -1

  // Quickshell gives no ordering guarantee between Process.exited and
  // StdioCollector.streamFinished. Draining the queued refresh from exited
  // alone let the NEXT read start and move stateReadEpoch before the finished
  // read's text had even been looked at -- so the stale text was then compared
  // against the new read's epoch and sailed straight through the guard written
  // to catch it. Both signals have to land before anything relaunches.
  property bool readStreamDone: false

  function refresh() {
    if (stateProc.running) { root.refreshQueued = true; return }
    root.refreshQueued = false
    root.stateReadEpoch = root.stateEpoch
    root.readStreamDone = false
    root.statePayloadInvalid = false
    root.stateExitCode = -1
    stateProc.running = true
    root.armWatchdog()
  }

  // Called from both of the read's end signals; acts only once both have landed.
  function finishRead() {
    if (stateProc.running || !root.readStreamDone) return
    root.armWatchdog()
    if (root.statePayloadInvalid && root.stateExitCode === 0) {
      root.publishError("omarchy-nightlight returned invalid state")
      root.statePayloadInvalid = false
    }
    if (root.refreshQueued) Qt.callLater(root.refresh)
  }

  // While the user is working the controls, a read must not take them back.
  readonly property bool busy: draggingName !== "" || debounce.running || applyProc.running

  // Exposed so the switches can show `busy` from inside PanelHero's nested
  // Component, where the Process id is out of scope.
  readonly property bool applyProcRunning: applyProc.running

  // ---- temporary pause ----------------------------------------------------
  // "Off for N minutes, then back on by itself", for editing a photo or grading
  // video, where a warm screen lies to you about colour.
  //
  // It rides on the CLI's existing `off`/`on`: `off` never writes the saved
  // file, so a pause cannot cost anyone their per-screen intensities, and `on`
  // brings each screen back to its own value rather than to a shared one.
  //
  // The countdown is a plain QML Timer living inside this plugin. It is not a
  // systemd timer or a cron entry on purpose: Omarchy runs nothing on uninstall,
  // so anything registered outside this folder would outlive `omarchy plugin
  // remove` forever. omarchy-shell is always running, so a Timer here starts and
  // dies with the plugin and leaves nothing behind.
  // Closing the drawer removes the brightness stops from the cursor's reach, so
  // a cursor parked on one has to be moved off it -- the house pattern is to
  // reclamp on every visibility change.
  function toggleDrawer() {
    root.showMore = !root.showMore
    if (!root.showMore && root.cursorIndex > 0 && (root.cursorIndex - 1) % 3 === 2)
      root.cursorIndex -= 1
  }

  // The advanced drawer starts closed on every open, so the panel someone sees
  // when they click the bar icon never grows.
  property bool showMore: false

  property double pauseUntil: 0
  readonly property bool paused: pauseUntil > 0
  property int pauseSecondsLeft: 0

  readonly property string pauseLabel: {
    if (!paused) return ""
    var mins = Math.ceil(pauseSecondsLeft / 60)
    return mins <= 1 ? "paused, 1 min left" : "paused, " + mins + " min left"
  }

  // Persisted, not just held in memory. `off` deliberately writes nothing to the
  // CLI's config, so if every instance is destroyed mid-pause -- a theme switch,
  // a config edit, any plugin add or remove reloads the shell -- nothing is left
  // anywhere that knows to turn the filter back on. The screens sit neutral with
  // their intensities still on disk, which reads as "the plugin broke".
  function startPause(minutes) {
    var until = Date.now() + Math.max(1, minutes) * 60000
    root.publishPause(until)
    persist({ pausedUntil: until })
    run(["off"])
  }

  function endPause() {
    if (!root.paused) return
    root.publishPause(0)
    persist({ pausedUntil: 0 })
    run(["on"])
  }

  // Called once at startup. A pause that expired while the shell was down ends
  // immediately; one still running is picked back up with its remaining time.
  // A bar surface is built per monitor, so this runs once per screen. Only the
  // expired branch acts on the machine, and it must act once: unguarded, two
  // monitors meant two `omarchy-nightlight on` processes and two independent
  // shell.json rewrites at every login, each snapshotting `settings` on its own
  // and able to drop the other's keys. Publishing the resumed pause is
  // per-instance state and stays unguarded.
  function resumePauseFromSettings() {
    var stored = Number(setting("pausedUntil", 0)) || 0
    if (stored <= 0) return
    if (Date.now() >= stored) {
      // Every instance clears its own snapshot; only the owner acts on the
      // machine. Gating persist() as well left the peers holding the expired
      // timestamp, and the next persist() from one of them -- a schedule edit,
      // say -- wrote it straight back to shell.json, resurrecting a pause that
      // had ended days earlier.
      persist({ pausedUntil: 0 })
      if (!root.isPollOwner()) return
      run(["on"])
      return
    }
    root.publishPause(stored)
  }

  function publishPause(until) {
    var items = peers()
    for (var i = 0; i < items.length; i++) {
      var peer = items[i]
      if (peer && typeof peer.adoptPause === "function") peer.adoptPause(until)
    }
  }

  function publishPhase(phase) {
    var items = peers()
    for (var i = 0; i < items.length; i++) {
      var peer = items[i]
      if (peer && typeof peer.adoptPhase === "function") peer.adoptPhase(phase)
    }
  }

  // Only the owner advances the phase, so unplugging the owner's monitor used to
  // hand a fresh instance an empty phase -- which then re-applied the current
  // one on its next tick and quietly undid a manual change made between
  // boundaries. Publishing it keeps every instance able to take over.
  function adoptPhase(phase) {
    root.schedulePhase = phase
  }

  function adoptPause(until) {
    root.pauseUntil = until
    root.pauseSecondsLeft = until > 0 ? Math.max(0, Math.round((until - Date.now()) / 1000)) : 0
  }

  // ---- schedule -----------------------------------------------------------
  // Off by default, and it stays that way unless someone turns it on: this
  // plugin's author runs the filter 24h a day, and a schedule that switched
  // itself on would be a surprise, not a feature.
  //
  // It schedules ON and OFF, not an intensity, so each screen keeps its own
  // value and a screen excused at 0% stays excused -- the whole point of the
  // plugin survives having a schedule. `nightPercent` is an escape hatch for
  // anyone who does want one shared number; it has no UI because forcing a
  // global intensity is the opposite of what most people install this for.
  readonly property bool scheduleEnabled: setting("scheduleEnabled", false) === true
  readonly property string scheduleOnAt: String(setting("scheduleOnAt", "20:00"))
  readonly property string scheduleOffAt: String(setting("scheduleOffAt", "07:00"))
  readonly property int scheduleNightPercent: Model.clampPercent(setting("nightPercent", 0))

  // "night" or "day"; empty until the first evaluation. Only a *change* acts, so
  // a manual override between boundaries is left alone until the next one.
  property string schedulePhase: ""
  property string runningSchedulePhase: ""

  // Bumped to force the schedule's text fields to re-read the stored value
  // after a rejected edit.
  property int scheduleFieldsRevision: 0

  // Settings go inline on this widget's shell.json entry, which is Omarchy's
  // rule for plugin settings -- no private settings file.
  //
  // Two hazards, both avoided here. The entry is snapshotted into one object in
  // a single pass rather than read property by property, because the derived
  // `schedule*` bindings update one signal at a time and a half-updated read
  // would persist a mixture of old and new. And the write is deferred with
  // Qt.callLater: writing back into the config these bindings are derived from,
  // from inside the evaluation that config triggered, is a binding loop, and Qt
  // drops such a write silently rather than telling you.
  function persist(values) {
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    for (var name in values) entry[name] = values[name]
    // Update the in-memory copy first and unconditionally. The disk write can be
    // unavailable -- no shell handed down, an older host -- and when it is, the
    // running session should still agree with itself rather than silently
    // keeping the old value.
    root.settings = entry
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    Qt.callLater(function() {
      if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, entry)
    })
  }

  function setScheduleEnabled(value) {
    // publishPhase, not a local write. The timer's first tick runs on the poll
    // owner, and clearing the phase only here left the owner still holding the
    // old one -- so re-enabling the schedule from a non-owner's panel hit
    // applySchedule's `phase === schedulePhase` guard and did nothing at all.
    // The schedule looked dead until the next boundary hours later.
    root.publishPhase("")
    persist({ scheduleEnabled: value === true })
    // No explicit apply here. The schedule timer has triggeredOnStart, so
    // `scheduleEnabled` turning true starts it and fires immediately -- and
    // with the phase just cleared that first tick is not a no-op. Calling
    // applySchedule as well ran the CLI twice and showed two OSDs per click.
  }

  function setScheduleTime(key, value) {
    if (Model.parseTime(value) < 0) {
      // Put the field back to the stored value. Returning quietly left `9:5`
      // sitting in a box whose binding had already been broken by typing, so
      // the panel showed a time the schedule was not using.
      root.scheduleFieldsRevision++
      return
    }
    var next = {}
    next[key] = Model.formatTime(Model.parseTime(value))
    persist(next)
    // Published, not local: applySchedule(true) below usually repairs the
    // divergence, but it early-returns when the schedule is off or paused, and
    // then this instance holds "" while the owner still holds the old phase.
    root.publishPhase("")
    Qt.callLater(function() { root.applySchedule(true) })
  }

  function applySchedule(force) {
    if (!root.scheduleEnabled || root.paused) return
    var phase = Model.phaseAt(new Date(), root.scheduleOnAt, root.scheduleOffAt)
    if (phase === "") return
    if (!force && phase === root.schedulePhase) return
    var args = phase === "night"
      ? [root.scheduleNightPercent > 0 ? String(root.scheduleNightPercent) : "on"]
      : ["off"]
    run(args, phase)
  }

  // ---- writing ------------------------------------------------------------
  // We never wait for a process. `Process.running = true` returns immediately,
  // so the UI keeps painting while bash runs. A command arriving while another
  // is in flight becomes `queued` and fires from onExited — that is what stops
  // a long drag from piling up processes.
  // One queue slot per output. A single global slot was right for repeated
  // writes to the same slider and wrong across screens: with applyProc busy,
  // touching HDMI-A-1's switch and then DP-2's dropped the first command
  // entirely -- while setPending had already moved its knob, so the panel
  // showed one thing and the screen did another until the next good poll.
  // Keyed by output, last-write-wins per output, which is what a slider needs
  // and what a second screen must not be caught by.
  property var queuedByOutput: ({})

  // Commands with no output of their own (`on`, `off`, the wheel's `+5`) share
  // one slot under this key: they are whole-machine gestures, so a newer one
  // genuinely does supersede an older one.
  readonly property string globalQueueKey: "\u0000global"

  // Keyed by output AND axis. On the output alone, a queued
  // `["DP-2","brightness","55"]` was replaced by a later `["DP-2","70"]`, so
  // releasing the brightness slider and then nudging the intensity slider
  // within the same ~200ms run dropped the brightness write entirely -- the
  // panel showed 55 until the next read snapped it back.
  function queueKeyFor(args) {
    if (args.length > 1 && root.byName[args[0]] !== undefined)
      return args[0] + "\u0000" + (args[1] === "brightness" ? "brightness" : "percent")
    return root.globalQueueKey
  }

  function startApply(entry) {
    // This is deliberately separate from run(): onExited has already removed
    // one entry, and starting it must not clear the entries still waiting.
    root.publishWrite()
    root.runningSchedulePhase = entry.schedulePhase
    applyProc.command = [root.command].concat(entry.args)
    applyProc.running = true
    root.armWatchdog()
  }

  function run(args, schedulePhase) {
    var entry = { args: args, schedulePhase: String(schedulePhase || "") }
    if (applyProc.running) {
      var next = {}
      for (var key in root.queuedByOutput) next[key] = root.queuedByOutput[key]
      next[queueKeyFor(args)] = entry
      root.queuedByOutput = next
      return
    }
    root.queuedByOutput = ({})
    root.startApply(entry)
  }

  // Pull one queued command, oldest key first. The rest stay queued and go out
  // as each process finishes.
  function dequeue() {
    for (var key in root.queuedByOutput) {
      var args = root.queuedByOutput[key]
      var rest = {}
      for (var other in root.queuedByOutput) if (other !== key) rest[other] = root.queuedByOutput[other]
      root.queuedByOutput = rest
      return args
    }
    return null
  }

  function setPending(name, percent, on) {
    var next = {}
    for (var key in root.pending) next[key] = root.pending[key]
    next[name] = {
      percent: Model.clampPercent(percent),
      on: on === true,
      saved: root.savedFor(name),
      brightness: root.brightnessFor(name)
    }
    root.pending = next
  }

  // Applying a percentage always names the output. A command without a name
  // skips outputs deliberately saved at 0%, so a slider on one of those would
  // otherwise do nothing at all.
  // A screen can be unplugged between the gesture and the command: the slider
  // release, the keyboard nudge and the per-screen switch all reach the CLI
  // with a name the daemon may no longer know, and its non-zero exit paints an
  // error banner across every screen for something the user did nothing wrong
  // to cause. (The debounce path cannot hit this -- `busy` freezes `names`
  // while a drag is live -- so the guard belongs here, on the commits.)
  function outputGone(name) {
    return root.names.indexOf(name) === -1
  }

  function applyPercent(name, value) {
    if (root.outputGone(name)) return
    var target = Model.clampPercent(value)
    setPending(name, target, target > 0)
    run([name, String(target)])
  }

  // Mid-drag the temperature is applied for real -- you have to see the colour
  // you are choosing -- but with --no-save, so the config file is not rewritten
  // for every intensity the slider merely passed through on its way. The write
  // happens once, from applyPercent(), when the drag is released.
  //
  // 180ms is the same debounce the first-party brightness slider uses: short
  // enough to feel immediate, long enough that a whole drag is a handful of
  // calls rather than one per pixel.
  function livePercent(name, value) {
    var target = Model.clampPercent(value)
    setPending(name, target, target > 0)
    run([name, String(target), "--no-save"])
  }

  function previewPercent(name, value) {
    setPending(name, value, Model.clampPercent(value) > 0)
    root.debouncedName = name
    root.debouncedBrightness = false
    debounce.restart()
  }

  // A switch is a momentary gesture, never a statement about intensity, so it
  // only ever sends `toggle` -- which the CLI applies without writing the saved
  // file. This matters most for a screen saved at 0%: that mark means "this one
  // stays neutral on purpose", and flicking its switch must not promote it to a
  // real percentage that would light it up again at the next login. Only the
  // slider writes.
  // Software brightness, on the same gamma ramp as the temperature. Same
  // live/commit split as the intensity slider: the drag applies with --no-save
  // so the screen follows the cursor, and the release is the one write.
  function setPendingBrightness(name, value) {
    var next = {}
    for (var key in root.pending) next[key] = root.pending[key]
    next[name] = {
      percent: root.percentFor(name),
      on: root.isOn(name),
      saved: root.savedFor(name),
      brightness: Model.clampBrightness(value)
    }
    root.pending = next
  }

  function liveBrightness(name, value) {
    var target = Model.clampBrightness(value)
    setPendingBrightness(name, target)
    run([name, "brightness", String(target), "--no-save"])
  }

  function applyBrightness(name, value) {
    if (root.outputGone(name)) return
    var target = Model.clampBrightness(value)
    setPendingBrightness(name, target)
    run([name, "brightness", String(target)])
  }

  function previewBrightness(name, value) {
    setPendingBrightness(name, value)
    root.debouncedName = name
    root.debouncedBrightness = true
    debounce.restart()
  }

  function nudgeBrightness(name, delta) {
    applyBrightness(name, brightnessFor(name) + delta)
  }

  function toggleScreen(name) {
    if (root.outputGone(name)) return
    var turningOn = !isOn(name)
    var saved = savedFor(name)
    // What the CLI will light it up at, mirrored here so the knob and the
    // number move at once. Prediction only -- nothing is written.
    var shown = saved > 0 ? saved : Model.DEFAULT_PERCENT
    setPending(name, turningOn ? shown : 0, turningOn)
    run([name, "toggle"])
  }

  function nudge(name, delta) {
    applyPercent(name, percentFor(name) + delta)
  }

  // Master control. Uses explicit `on`/`off` rather than `toggle` so the
  // gesture is deterministic when screens disagree. `on` honours the outputs
  // saved at 0%, which is exactly what should happen: a screen you chose to
  // keep clean stays clean.
  function setAll(turningOn) {
    var next = {}
    for (var i = 0; i < root.names.length; i++) {
      var name = root.names[i]
      var saved = root.savedFor(name)
      next[name] = {
        percent: turningOn ? saved : 0,
        on: turningOn && saved > 0,
        saved: saved
      }
    }
    root.pending = next
    run([turningOn ? "on" : "off"])
  }

  function toggleAll() { setAll(!root.anyOn) }

  // ---- one cursor for keyboard and mouse ---------------------------------
  // Flat index: 0 is the master switch; then for screen i, 1+i*2 is its switch
  // and 2+i*2 is its slider. Colours come from `hasCursor`, never from
  // `containsMouse` — that is what guarantees a single highlight on screen,
  // the same contract the first-party panels follow.
  property bool cursorActive: false
  property int cursorIndex: 0
  readonly property int cursorMax: Math.max(0, screenCount * 3)

  // Three stops per screen: its switch, its intensity slider, its brightness
  // slider. The brightness stop only exists while the drawer is open, so
  // moveCursor() steps over it rather than the stride changing underneath the
  // indices -- an index that means a different control depending on a boolean
  // is how off-by-one bugs get in.
  function switchIndex(i) { return 1 + i * 3 }
  function sliderIndex(i) { return 2 + i * 3 }
  function brightnessIndex(i) { return 3 + i * 3 }

  function placeCursor(index) {
    root.cursorActive = true
    root.cursorIndex = index
  }

  function moveCursor(dy) {
    var step = dy > 0 ? 1 : -1
    var next = root.cursorIndex + step
    // Skip the brightness stop while its slider is not on screen.
    if (!root.showMore && next > 0 && (next - 1) % 3 === 2) next += step
    root.cursorIndex = Math.max(0, Math.min(root.cursorMax, next))
    if (!root.showMore && root.cursorIndex > 0 && (root.cursorIndex - 1) % 3 === 2)
      root.cursorIndex -= step
    keepCursorVisible()
  }

  function cursorScreen() {
    if (root.cursorIndex <= 0) return ""
    var i = Math.floor((root.cursorIndex - 1) / 3)
    return i < root.names.length ? root.names[i] : ""
  }

  function cursorOnSlider() {
    return root.cursorIndex > 0 && (root.cursorIndex - 1) % 3 === 1
  }

  function cursorOnBrightness() {
    return root.cursorIndex > 0 && (root.cursorIndex - 1) % 3 === 2
  }

  function activateCursor() {
    if (root.cursorIndex === 0) {
      root.toggleAll()
      return
    }
    var name = cursorScreen()
    if (name !== "") root.toggleScreen(name)
  }

  function nudgeCursor(delta) {
    var name = cursorScreen()
    if (name === "") return
    if (root.cursorOnBrightness()) root.nudgeBrightness(name, delta)
    else root.nudge(name, delta)
  }

  // Keeps the cursor row inside the scroll area when there are many screens.
  // Rows have a uniform height, so a proportional scroll is enough here.
  // Registered by each cursor-addressable row so scrolling can map the real
  // item instead of guessing. The proportional version assumed uniform rows,
  // which stopped being true the moment the drawer added a second slider and
  // its own section to the column.
  property var cursorItems: ({})

  function registerCursorItem(index, item) {
    var next = {}
    for (var key in root.cursorItems) next[key] = root.cursorItems[key]
    next[index] = item
    root.cursorItems = next
  }

  function keepCursorVisible() {
    if (!scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    if (maxY <= 0) return
    if (root.cursorIndex === 0) {
      flick.contentY = 0
      return
    }

    var item = root.cursorItems[root.cursorIndex]
    if (!item || item.height === undefined) return
    var margin = 6
    var point = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = point.y
    var bottom = top + (item.height || 0)
    if (top < flick.contentY + margin)
      flick.contentY = Math.max(0, Math.min(maxY, top - margin))
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = Math.max(0, Math.min(maxY, bottom + margin - flick.height))
  }


  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The host injects `bar`, `moduleName` and `settings` after this item is
  // constructed, so Component.onCompleted runs too early to read any of them --
  // a pause stored in the settings was never seen, and isPollOwner() had no bar
  // to ask. Deferring past the current event-loop pass puts all three in place
  // first, and Qt.callLater collapses the three triggers into one run.
  property bool started: false

  function startOnce() {
    if (root.started || !root.bar) return
    root.started = true
    if (root.isPollOwner()) root.refresh()
    root.resumePauseFromSettings()
  }

  Component.onCompleted: Qt.callLater(startOnce)
  onBarChanged: Qt.callLater(startOnce)
  onSettingsChanged: Qt.callLater(startOnce)


  // Re-reading on open is not optional: the intensity may have changed from
  // outside (a keybinding, the Omarchy menu, a terminal call), and the panel
  // has to open showing the truth.
  onOpenedChanged: {
    if (!opened) return
    refresh()
    root.showMore = false
    root.cursorIndex = 0
    // Do not paint the cursor before the user navigates or hovers.
    root.cursorActive = false
  }

  // Open: a short poll picks up external changes live. Closed: a long one keeps
  // the bar glyph honest without spawning processes for nothing.
  //
  // wl-gammarelay-rs does emit DBus PropertiesChanged, and subscribing would be
  // cheaper than polling — but that would mean talking to the backend directly
  // from QML, which is precisely the coupling this plugin avoids so the CLI
  // stays the single place that knows how the filter is applied and saved.
  // Only the instance with the panel open polls fast, and only one panel can be
  // open at a time (the bar's popout coordinator sees to that), so this is one
  // process every two seconds no matter how many screens exist.
  Timer {
    interval: 2000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // Closed, a single owner keeps every bar glyph honest on a slow cadence. The
  // siblings sit silent and take the result through publishState().
  Timer {
    interval: 20000
    running: !root.opened
    repeat: true
    onTriggered: if (root.isPollOwner()) root.refresh()
  }

  // Ticks only while a pause is running.
  Timer {
    interval: 1000
    running: root.paused
    repeat: true
    onTriggered: {
      root.pauseSecondsLeft = Math.max(0, Math.round((root.pauseUntil - Date.now()) / 1000))
      if (root.pauseSecondsLeft <= 0 && root.isPollOwner()) root.endPause()
    }
  }

  // One instance evaluates the schedule; the resulting state reaches the others
  // through the normal publish path. 30s is fine granularity for a boundary
  // measured in minutes and costs nothing when the schedule is off.
  Timer {
    interval: 30000
    running: root.scheduleEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: if (root.isPollOwner()) root.applySchedule(false)
  }

  // A Process that never finishes stops the widget forever: refresh() guards on
  // !stateProc.running and run() on applyProc.running, and nothing else ever
  // clears either. It is reachable rather than theoretical -- the CLI blocks
  // while it waits for the daemon, which is exactly the hyprsunset-conflict case
  // the warning exists for. Same shape as the Tailscale service's pollWatchdog,
  // for the same reason: a panel that silently stops refreshing stays stopped.
  //
  // It measures the CURRENT invocation: it is restarted whenever a process
  // starts, and stopped when none is left. Free-running on wall-clock phase, it
  // killed whatever happened to be in flight at the tick -- so the real timeout
  // was anywhere from 0 to 15s, and a healthy apply issued 100ms before a tick
  // was SIGTERMed with its queue thrown away, snapping the switch back under
  // the user. On a fresh install, where the CLI legitimately waits ~4s for the
  // daemon, that window is wide.
  Timer {
    id: procWatchdog
    interval: 15000
    running: false
    repeat: false
    onTriggered: {
      if (stateProc.running) stateProc.running = false
      if (applyProc.running) {
        applyProc.running = false
        root.runningSchedulePhase = ""
        // Whatever was queued behind it is stale by now; drop it rather than
        // firing a command the user asked for fifteen seconds ago.
        root.queuedByOutput = ({})
        root.pending = ({})
      }

      // A process that ignored the kill -- SIGTERM swallowed, or wedged on a
      // dead bus -- leaves `running` true. With repeat:false and nothing here,
      // the timer stopped and the widget stayed wedged with no further attempt.
      if (stateProc.running || applyProc.running) {
        procWatchdog.restart()
        return
      }

      // The read that was killed will never deliver a stream, so release the
      // gate and go get a fresh one rather than sitting on stale state.
      root.readStreamDone = true
      root.refreshQueued = false
      Qt.callLater(root.refresh)
    }
  }

  // Arm on the launch that needs watching and leave it alone after that.
  //
  // restart() here was worse than the bug it replaced: with the panel open a
  // refresh lands every 2s, well inside the 15s deadline, so every poll pushed
  // the deadline out ahead of a hung apply -- forever. `busy` stayed true, the
  // panel froze on its optimistic values and never recovered. The shell's own
  // Tailscale poll watchdog documents this exact trap and does the same thing
  // this now does.
  function armWatchdog() {
    if (stateProc.running || applyProc.running) {
      if (!procWatchdog.running) procWatchdog.start()
    } else {
      procWatchdog.stop()
    }
  }

  Timer {
    id: debounce
    interval: 180
    repeat: false
    onTriggered: {
      if (root.debouncedName === "") return
      if (root.debouncedBrightness) root.liveBrightness(root.debouncedName, root.brightnessFor(root.debouncedName))
      else root.livePercent(root.debouncedName, root.percentFor(root.debouncedName))
    }
  }

  Process {
    id: stateProc
    // --no-start is not optional here, it is the whole promise of the plugin:
    // merely having the widget enabled must not start wl-gammarelay-rs and must
    // not take the Wayland gamma control away from whatever holds it. Without
    // the flag this poll ran ensure_daemon every 20s, so within 20 seconds of
    // enabling the widget a daemon nobody asked for claimed every output --
    // and Omarchy's own `omarchy toggle nightlight` (hyprsunset) silently
    // stopped working for the rest of the session, for a user who never even
    // opened the panel. The daemon starts on the first real request instead.
    command: [root.command, "--json", "--no-start"]
    stdout: StdioCollector {
      id: stateOut
      waitForEnd: true
      onStreamFinished: {
        root.readStreamDone = true
        var state = Model.parseState(text)
        if (!state) {
          root.statePayloadInvalid = true
          root.finishRead()
          return
        } // unusable: keep last good state
        // Written to since this read began: it describes a world that no longer
        // exists. Drop it; the queued refresh below fetches the real one.
        if (root.stateReadEpoch !== root.stateEpoch) { root.finishRead(); return }
        root.publishState(state.names, state.byName, state.warning)
        root.finishRead()
      }
    }
    stderr: StdioCollector { id: stateErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.stateExitCode = exitCode
      root.armWatchdog()
      root.finishRead()
      if (exitCode === 0) {
        if (root.statePayloadInvalid) {
          root.publishError("omarchy-nightlight returned invalid state")
          root.statePayloadInvalid = false
        }
        return
      }
      // Missing dependency, dead daemon, hyprsunset holding the outputs: the
      // CLI explains itself on stderr, so show that rather than a silent
      // widget. State stays "unknown" instead of showing an invented zero, and
      // every screen's glyph says the same thing.
      root.publishError(Model.clampMessage(stateErr.text) || "omarchy-nightlight failed")
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function(exitCode) {
      var completedSchedulePhase = root.runningSchedulePhase
      root.runningSchedulePhase = ""
      if (exitCode !== 0)
        root.publishError(Model.clampMessage(applyErr.text) || "omarchy-nightlight failed")
      else if (completedSchedulePhase !== "")
        root.publishPhase(completedSchedulePhase)

      var next = root.dequeue()
      if (next) {
        root.startApply(next)
        return
      }
      root.armWatchdog()
      root.refresh()
    }
  }

  // The one handler the target permits. `open`/`close` land on whichever
  // instance won the registration, which is what omarchy.monitor does too;
  // `refresh` and `state` are relayed so a scripted change reaches every screen
  // rather than only the one that answered.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function state(): string {
      return JSON.stringify({
        loaded: root.stateLoaded,
        screens: root.screenCount,
        on: root.screensOn,
        error: root.errorText,
        outputs: root.names.map(function(name) {
          return { name: name, percent: root.percentFor(name), on: root.isOn(name), saved: root.savedFor(name) }
        })
      })
    }
  }

  // ---- bar glyph ----------------------------------------------------------
  // The same glyph Omarchy's own night-light indicator uses: no point inventing
  // a symbol for something the desktop already names and draws. `dimmed` is the
  // first-party convention for an inactive bar glyph — same shape, 45% opacity.
  // No colour of our own anywhere: the active theme decides.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰔎"
    // Dimmed when off AND when the state is unknown. Requiring stateLoaded meant
    // a failed read left the glyph undimmed, which reads as "the filter is on"
    // at exactly the moment nothing is known.
    dimmed: !root.stateLoaded || !root.anyOn
    useActiveColor: false
    tooltipText: root.errorText !== "" ? root.errorText : ("Night light: " + root.summary)

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleAll()
      else root.toggle()
    }

    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      // Relative change on every screen. The CLI skips the ones saved at 0% on
      // its own, so the wheel never lights up a screen meant to stay neutral.
      root.run([(wheel.steps > 0 ? "+" : "-") + Math.abs(wheel.steps * 5)])
    }
  }

  // ---- panel --------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    // The height cap is what keeps a five-monitor desk from blowing the panel
    // off the screen: past it the list scrolls instead of growing.
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0 && (root.cursorOnSlider() || root.cursorOnBrightness())) root.nudgeCursor(dx * 5)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: content.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        // Only let the content be dragged when it really overflows, otherwise a
        // drag meant for a slider could scroll the list under it.
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: content.implicitHeight > scrollArea.height
        }

        Column {
          id: content
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          // Hero: glyph, name, status line, and the master switch on the
          // trailing edge. Same shape as the Tailscale and Audio panels, down
          // to the wrapper Item — a `trailingControl` Component is built by a
          // Loader inside PanelHero, so it reaches panel state through `header`
          // rather than assuming which `root` it can see.
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight

            readonly property bool ringVisible: root.cursorActive && root.cursorIndex === 0
            readonly property bool on: root.anyOn
            // In flight: the CLI has been asked but has not answered yet.
            readonly property bool working: root.applyProcRunning
            readonly property string hint: root.anyOn ? "Turn off on every screen" : "Turn on where saved"
            readonly property bool moreOpen: root.showMore
            function focusHero() { root.placeCursor(0) }
            function flip() { root.toggleAll() }
            function toggleMore() { root.toggleDrawer() }

            PanelHero {
              id: hero
              width: parent.width
              title: "Night Light"
              // A running pause takes over the status line, so it is visible
              // without opening anything -- it is the one state that expires on
              // its own and would be baffling if it were hidden.
              meta: root.paused ? root.pauseLabel : root.summary
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.anyOn ? 1.0 : 0.5

              // Status only — the switch owns turning things on and off, for
              // mouse and keyboard alike.
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: "󰔎"
                  color: hero.foreground
                  font.family: hero.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              // A single small glyph beside the master switch is the whole cost
              // of the extra features: everything they need lives behind it, so
              // the panel at rest is still just the list of screens.
              trailingControl: Component {
                Item {
                  implicitWidth: trailingRow.implicitWidth
                  implicitHeight: trailingRow.implicitHeight

                  Row {
                    id: trailingRow
                    spacing: Style.space(4)

                    Button {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "\u22EF"
                      tooltipText: "Brightness, pause and schedule"
                      selected: header.moreOpen
                      bordered: false
                      focusable: true
                      foreground: hero.foreground
                      fontFamily: hero.fontFamily
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      onClicked: header.toggleMore()
                    }

                    ToggleSwitch {
                      id: masterSwitch
                      anchors.verticalCenter: parent.verticalCenter
                      checked: header.on
                      // `busy` swallows further clicks while the process runs
                      // but leaves hover and the tooltip alone, so a slow apply
                      // cannot be double-fired into a queue of contradicting
                      // commands.
                      busy: header.working
                      hasCursor: header.ringVisible
                      foreground: hero.foreground
                      onHovered: function(on) { if (on) header.focusHero() }
                      onToggled: header.flip()

                      PanelToolTip {
                        visible: masterSwitch.containsMouse
                        text: header.hint
                        fontFamily: hero.fontFamily
                      }
                    }
                  }
                }
              }
            }
          }

          // Whatever the CLI complained about — a missing wl-gammarelay-rs,
          // hyprsunset holding the outputs — said in the panel rather than only
          // in the shell log, where nobody will look.
          Text {
            textFormat: Text.PlainText
            visible: root.errorText !== ""
            width: parent.width
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // Advisory rather than fatal, so it is dimmed rather than urgent --
          // but always shown, because the state it describes makes every
          // control in this panel look broken.
          Text {
            textFormat: Text.PlainText
            visible: root.warningText !== ""
            width: parent.width
            text: root.warningText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          Text {
            textFormat: Text.PlainText
            visible: root.noScreens
            width: parent.width
            text: "No screens available."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSectionHeader {
            visible: !root.noScreens
            text: root.screenCount === 1 ? "SCREEN" : "SCREENS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // ---------- one row per screen ----------
          // The model is `names` (strings), not the list of objects: that way a
          // value-only read never recreates the delegates and never drops a
          // drag in progress.
          Repeater {
            model: root.names

            Column {
              id: screenRow
              required property string modelData
              required property int index

              readonly property string name: modelData
              readonly property bool on: root.isOn(name)
              readonly property int percent: root.percentFor(name)
              readonly property int brightness: root.brightnessFor(name)

              width: content.width
              spacing: Style.space(4)

              Item {
                width: parent.width
                implicitHeight: Math.max(screenName.implicitHeight, screenSwitch.implicitHeight)

                Text {
                  id: screenName
                  textFormat: Text.PlainText
                  text: screenRow.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  elide: Text.ElideRight
                  anchors.left: parent.left
                  anchors.right: screenValue.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  opacity: screenRow.on ? 1.0 : 0.65
                }

                Text {
                  id: screenValue
                  textFormat: Text.PlainText
                  // While dragging the number follows `liveValue`; otherwise it
                  // would only move when the debounce fired.
                  text: screenRow.on || screenSlider.dragging
                    ? Math.round(screenSlider.dragging ? screenSlider.liveValue : screenRow.percent) + "%"
                    : "off"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: screenSwitch.left
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                }

                ToggleSwitch {
                  id: screenSwitch
                  checked: screenRow.on
                  busy: root.applyProcRunning
                  hasCursor: root.cursorActive && root.cursorIndex === root.switchIndex(screenRow.index)
                  foreground: root.foreground
                  // A compact switch on purpose: with five screens the panel
                  // has to fit without turning into a column of big tracks.
                  trackHeight: Math.max(18, Math.round(Style.spacing.controlHeight * 0.45))
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  onHovered: function(on) {
                    if (on) root.placeCursor(root.switchIndex(screenRow.index))
                  }
                  onToggled: root.toggleScreen(screenRow.name)
                }
              }

              CursorSurface {
                width: parent.width
                height: screenSlider.implicitHeight + Style.spacing.controlGap
                hasCursor: root.cursorActive && root.cursorIndex === root.sliderIndex(screenRow.index)
                foreground: root.foreground
                outline: true

                PanelSlider {
                  id: screenSlider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 0
                  maximum: 100
                  // Fine control: one point per wheel notch and per arrow key
                  // on the track. The panel's h/l keys still move in fives,
                  // which is the coarse gesture.
                  step: 1
                  integer: true
                  value: screenRow.percent
                  opacity: screenRow.on ? 1.0 : 0.6

                  // `draggingName` freezes the polls for as long as the gesture
                  // lasts.
                  onDraggingChanged: root.draggingName = dragging ? screenRow.name : ""
                  // A delegate destroyed mid-drag never reaches onReleased, so
                  // the lock has to be dropped here or it is held for the life
                  // of the shell. Guarded by name so a rebuild cannot clear a
                  // lock that belongs to another row.
                  Component.onDestruction: if (root.draggingName === screenRow.name) root.draggingName = ""

                  onMoved: function(v) { root.previewPercent(screenRow.name, v) }
                  onReleased: function(v) {
                    // Only cancel the debounce if it is this slider's. It used
                    // to stop unconditionally, so releasing one row's slider
                    // discarded a write another row had pending -- the value
                    // survived in `pending` but was never sent, and reverted on
                    // the next poll.
                    if (root.debouncedName === screenRow.name && !root.debouncedBrightness) debounce.stop()
                    root.applyPercent(screenRow.name, v)
                  }
                  // Right-click toggles this screen alone, the same way the
                  // first-party audio slider mutes the channel it belongs to.
                  onRightClicked: root.toggleScreen(screenRow.name)
                }

                Component.onCompleted: root.registerCursorItem(root.sliderIndex(screenRow.index), this)

                HoverHandler {
                  onHoveredChanged: if (hovered) root.placeCursor(root.sliderIndex(screenRow.index))
                }
              }

              // Software brightness for this screen, revealed with the drawer.
              // It is not in the resting panel on purpose: two full sliders per
              // row doubles the height of the one view this plugin is for, and
              // on a five-monitor desk that is the difference between reading
              // the panel and scrolling it.
              Item {
                width: parent.width
                visible: root.showMore
                implicitHeight: visible ? brightnessRow.implicitHeight : 0

                Column {
                  id: brightnessRow
                  width: parent.width
                  spacing: Style.space(2)

                  Item {
                    width: parent.width
                    implicitHeight: brightnessCaption.implicitHeight

                    Text {
                      id: brightnessCaption
                      textFormat: Text.PlainText
                      text: "BRIGHTNESS"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1.2
                      anchors.left: parent.left
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : screenRow.brightness) + "%"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(6)
                    }
                  }

                  CursorSurface {
                    width: parent.width
                    height: brightnessSlider.implicitHeight + Style.spacing.controlGap
                    hasCursor: root.cursorActive && root.cursorIndex === root.brightnessIndex(screenRow.index)
                    foreground: root.foreground
                    outline: true

                    PanelSlider {
                      id: brightnessSlider
                      bar: root.bar
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(6)
                      anchors.rightMargin: Style.space(6)
                      // The floor is the daemon's: below 10% the screen is
                      // unreadable and the only way back would be the CLI.
                      minimum: 10
                      maximum: 100
                      step: 1
                      integer: true
                      value: screenRow.brightness

                      onDraggingChanged: root.draggingName = dragging ? screenRow.name : ""
                      Component.onDestruction: if (root.draggingName === screenRow.name) root.draggingName = ""
                      onMoved: function(v) { root.previewBrightness(screenRow.name, v) }
                      onReleased: function(v) {
                        if (root.debouncedName === screenRow.name && root.debouncedBrightness) debounce.stop()
                        root.applyBrightness(screenRow.name, v)
                      }
                    }

                    Component.onCompleted: root.registerCursorItem(root.brightnessIndex(screenRow.index), this)

                    HoverHandler {
                      onHoveredChanged: if (hovered) root.placeCursor(root.brightnessIndex(screenRow.index))
                    }
                  }
                }
              }
            }
          }

          // ---------- advanced drawer ----------
          // Hidden behind the hero's small glyph and closed on every open, so
          // none of this is in the way of the one thing the panel is for.
          Column {
            id: drawer
            width: parent.width
            spacing: Style.space(10)
            visible: root.showMore

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }

            // ---- temporary pause ----
            Item {
              width: parent.width
              implicitHeight: Math.max(pauseHeader.implicitHeight, pauseActions.implicitHeight)

              PanelSectionHeader {
                id: pauseHeader
                text: "PAUSE"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Row {
                id: pauseActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                // While a pause runs there is one thing worth offering, and it
                // is not another duration.
                Button {
                  visible: root.paused
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Resume now"
                  bordered: true
                  focusable: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(2)
                  onClicked: root.endPause()
                }

                Repeater {
                  model: root.paused ? [] : [15, 30, 60]

                  Button {
                    required property int modelData
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData >= 60 ? (modelData / 60) + "h" : modelData + "m"
                    tooltipText: "Turn the filter off for " + modelData + " minutes, then back on"
                    bordered: true
                    focusable: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(2)
                    onClicked: root.startPause(modelData)
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: !root.paused
              text: "Off for a while, then back on by itself — for editing photos or video."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }

            // ---- schedule ----
            Item {
              width: parent.width
              implicitHeight: Math.max(scheduleHeader.implicitHeight, scheduleSwitch.implicitHeight)

              PanelSectionHeader {
                id: scheduleHeader
                text: "SCHEDULE"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              ToggleSwitch {
                id: scheduleSwitch
                checked: root.scheduleEnabled
                foreground: root.foreground
                trackHeight: Math.max(18, Math.round(Style.spacing.controlHeight * 0.45))
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onToggled: root.setScheduleEnabled(!root.scheduleEnabled)
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Turns the filter on and off at fixed times. Each screen keeps its own intensity, and a screen set to 0% stays neutral."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              visible: root.scheduleEnabled
              spacing: Style.space(10)

              Column {
                spacing: Style.space(3)

                Text {
                  textFormat: Text.PlainText
                  text: "ON AT"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                }

                TextField {
                  id: onAtField
                  width: Style.space(70)
                  // Reading the revision makes a rejected edit re-run this
                  // binding and put the stored time back in the box.
                  text: { root.scheduleFieldsRevision; return root.scheduleOnAt }
                  placeholderText: "20:00"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  verticalPadding: Style.space(3)
                  // Commit on Enter or on losing focus, never per keystroke:
                  // "2" on the way to "20:00" is a valid time and would move the
                  // boundary to 02:00 for as long as it took to type the rest.
                  onEditingFinished: root.setScheduleTime("scheduleOnAt", text)
                }
              }

              Column {
                spacing: Style.space(3)

                Text {
                  textFormat: Text.PlainText
                  text: "OFF AT"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                }

                TextField {
                  id: offAtField
                  width: Style.space(70)
                  // Reading the revision makes a rejected edit re-run this
                  // binding and put the stored time back in the box.
                  text: { root.scheduleFieldsRevision; return root.scheduleOffAt }
                  placeholderText: "07:00"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  verticalPadding: Style.space(3)
                  onEditingFinished: root.setScheduleTime("scheduleOffAt", text)
                }
              }
            }
          }
        }
      }
    }
  }
}

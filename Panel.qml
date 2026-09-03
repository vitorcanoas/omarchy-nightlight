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
  // exactly one handler. `manageIpc: false` is meant to stand the base class's
  // handler down so ours can own the target -- but on Quickshell 0.3.1 a
  // disabled IpcHandler still registers, and the base one won the race and
  // shadowed ours: the target resolved, and every method on it answered
  // "Function not found".
  //
  // Leaving `ipcTarget` empty is what actually settles it. The base handler has
  // no target left to claim, our own IpcHandler below owns the name outright,
  // and nothing else on Panel depends on the property.
  manageIpc: false

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

  // A command queued while another is in flight (last one wins).
  property var queued: null

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

  function publishError(message) {
    var items = peers()
    for (var i = 0; i < items.length; i++) {
      var peer = items[i]
      if (peer && typeof peer.adoptError === "function") peer.adoptError(message)
    }
  }

  function adoptState(names, byName, warning) {
    // The output list always applies (a monitor plugged or unplugged), but it is
    // only reassigned when it really changed, so the delegates stay put.
    if (Model.signature(names) !== Model.signature(root.names)) {
      root.names = names
      root.cursorIndex = Math.min(root.cursorIndex, Math.max(0, names.length * 3))
    }

    // Values, by contrast, only land when this instance is not mid-gesture —
    // otherwise a poll would yank the slider out of the user's hand. Only the
    // instance being dragged is busy; its siblings still take the update.
    if (root.busy) return
    root.byName = byName
    root.pending = ({})
    root.stateLoaded = true
    root.errorText = ""
    root.warningText = String(warning || "")
  }

  function adoptError(message) {
    root.stateLoaded = false
    root.errorText = message
  }

  // ---- reading ------------------------------------------------------------
  function refresh() {
    if (!stateProc.running) stateProc.running = true
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

  function startPause(minutes) {
    root.publishPause(Date.now() + Math.max(1, minutes) * 60000)
    run(["off"])
  }

  function endPause() {
    if (!root.paused) return
    root.publishPause(0)
    run(["on"])
  }

  function publishPause(until) {
    var items = peers()
    for (var i = 0; i < items.length; i++) {
      var peer = items[i]
      if (peer && typeof peer.adoptPause === "function") peer.adoptPause(until)
    }
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
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    for (var name in values) entry[name] = values[name]
    root.settings = entry
    Qt.callLater(function() {
      if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, entry)
    })
  }

  function setScheduleEnabled(value) {
    persist({ scheduleEnabled: value === true })
    root.schedulePhase = ""
    // Apply straight away rather than waiting up to 30s: switching a schedule on
    // and watching nothing happen reads as broken.
    if (value === true) Qt.callLater(function() { root.applySchedule(true) })
  }

  function setScheduleTime(key, value) {
    if (Model.parseTime(value) < 0) return // leave the stored time alone
    var next = {}
    next[key] = Model.formatTime(Model.parseTime(value))
    persist(next)
    root.schedulePhase = ""
    Qt.callLater(function() { root.applySchedule(true) })
  }

  function applySchedule(force) {
    if (!root.scheduleEnabled || root.paused) return
    var phase = Model.phaseAt(new Date(), root.scheduleOnAt, root.scheduleOffAt)
    if (phase === "") return
    if (!force && phase === root.schedulePhase) return
    root.schedulePhase = phase
    if (phase === "night") run([root.scheduleNightPercent > 0 ? String(root.scheduleNightPercent) : "on"])
    else run(["off"])
  }

  // ---- writing ------------------------------------------------------------
  // We never wait for a process. `Process.running = true` returns immediately,
  // so the UI keeps painting while bash runs. A command arriving while another
  // is in flight becomes `queued` and fires from onExited — that is what stops
  // a long drag from piling up processes.
  function run(args) {
    if (applyProc.running) {
      root.queued = args
      return
    }
    root.queued = null
    applyProc.command = [root.command].concat(args)
    applyProc.running = true
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
  function applyPercent(name, value) {
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
    flick.contentY = Math.max(0, Math.min(maxY, maxY * (root.cursorIndex / Math.max(1, root.cursorMax))))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

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
    command: [root.command, "--json"]
    stdout: StdioCollector {
      id: stateOut
      waitForEnd: true
      onStreamFinished: {
        var state = Model.parseState(text)
        if (!state) return // unusable output: keep the last good state
        root.publishState(state.names, state.byName, state.warning)
      }
    }
    stderr: StdioCollector { id: stateErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) return
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
      if (exitCode !== 0)
        root.publishError(Model.clampMessage(applyErr.text) || "omarchy-nightlight failed")

      if (root.queued) {
        var next = root.queued
        root.queued = null
        root.run(next)
        return
      }
      root.refresh()
    }
  }

  // The one handler the target permits. `open`/`close` land on whichever
  // instance won the registration, which is what omarchy.monitor does too;
  // `refresh` and `state` are relayed so a scripted change reaches every screen
  // rather than only the one that answered.
  IpcHandler {
    target: "vitorcanoas.nightlight"

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
    dimmed: root.stateLoaded && !root.anyOn
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
            function toggleMore() { root.showMore = !root.showMore }

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

          PanelSectionHeader {
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

                  onMoved: function(v) { root.previewPercent(screenRow.name, v) }
                  onReleased: function(v) {
                    debounce.stop()
                    root.applyPercent(screenRow.name, v)
                  }
                  // Right-click toggles this screen alone, the same way the
                  // first-party audio slider mutes the channel it belongs to.
                  onRightClicked: root.toggleScreen(screenRow.name)
                }

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
                      onMoved: function(v) { root.previewBrightness(screenRow.name, v) }
                      onReleased: function(v) {
                        debounce.stop()
                        root.applyBrightness(screenRow.name, v)
                      }
                    }

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
                  text: root.scheduleOnAt
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
                  text: root.scheduleOffAt
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

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

  // Name of the output being dragged, and the one the debounce will write.
  property string draggingName: ""
  property string debouncedName: ""

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

  // ---- reading ------------------------------------------------------------
  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  // While the user is working the controls, a read must not take them back.
  readonly property bool busy: draggingName !== "" || debounce.running || applyProc.running

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
      saved: root.savedFor(name)
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

  // Dragging only previews; the CLI is called once the gesture settles. 180ms
  // is the same debounce the first-party brightness slider uses: short enough
  // to feel immediate, long enough that a whole drag is a couple of calls
  // rather than one per pixel.
  function previewPercent(name, value) {
    setPending(name, value, Model.clampPercent(value) > 0)
    root.debouncedName = name
    debounce.restart()
  }

  function toggleScreen(name) {
    var turningOn = !isOn(name)
    var saved = savedFor(name)

    if (turningOn && saved === 0) {
      // An output saved at 0% is deliberately neutral, so `toggle` would
      // re-apply 0% and the switch would appear dead. Send an explicit
      // percentage so the gesture means something.
      applyPercent(name, Model.DEFAULT_PERCENT)
      return
    }

    setPending(name, turningOn ? saved : 0, turningOn)
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
  readonly property int cursorMax: Math.max(0, screenCount * 2)

  function switchIndex(i) { return 1 + i * 2 }
  function sliderIndex(i) { return 2 + i * 2 }

  function placeCursor(index) {
    root.cursorActive = true
    root.cursorIndex = index
  }

  function moveCursor(dy) {
    root.cursorIndex = Math.max(0, Math.min(root.cursorMax, root.cursorIndex + (dy > 0 ? 1 : -1)))
    keepCursorVisible()
  }

  function cursorScreen() {
    if (root.cursorIndex <= 0) return ""
    var i = Math.floor((root.cursorIndex - 1) / 2)
    return i < root.names.length ? root.names[i] : ""
  }

  function cursorOnSlider() {
    return root.cursorIndex > 0 && root.cursorIndex % 2 === 0
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
    if (name !== "") root.nudge(name, delta)
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
  Timer {
    interval: root.opened ? 2000 : 20000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: debounce
    interval: 180
    repeat: false
    onTriggered: {
      if (root.debouncedName === "") return
      root.applyPercent(root.debouncedName, root.percentFor(root.debouncedName))
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

        // The output list always applies (a monitor plugged or unplugged), but
        // it is only reassigned when it really changed, so the delegates stay.
        if (Model.signature(state.names) !== Model.signature(root.names)) {
          root.names = state.names
          root.cursorIndex = Math.min(root.cursorIndex, Math.max(0, state.names.length * 2))
        }

        // Values, by contrast, only land when the user is not mid-gesture —
        // otherwise a poll would yank the slider out of their hand.
        if (root.busy) return
        root.byName = state.byName
        root.pending = ({})
        root.stateLoaded = true
        root.errorText = ""
      }
    }
    stderr: StdioCollector { id: stateErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) return
      // Missing dependency, dead daemon, hyprsunset holding the outputs: the
      // CLI explains itself on stderr, so show that rather than a silent
      // widget. State stays "unknown" instead of showing an invented zero.
      root.stateLoaded = false
      root.errorText = Model.clampMessage(stateErr.text) || "omarchy-nightlight failed"
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.errorText = Model.clampMessage(applyErr.text) || "omarchy-nightlight failed"

      if (root.queued) {
        var next = root.queued
        root.queued = null
        root.run(next)
        return
      }
      root.refresh()
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
        else if (dx !== 0 && root.cursorOnSlider()) root.nudgeCursor(dx * 5)
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
            readonly property string hint: root.anyOn ? "Turn off on every screen" : "Turn on where saved"
            function focusHero() { root.placeCursor(0) }
            function flip() { root.toggleAll() }

            PanelHero {
              id: hero
              width: parent.width
              title: "Night Light"
              meta: root.summary
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

              trailingControl: Component {
                ToggleSwitch {
                  id: masterSwitch
                  checked: header.on
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
                  step: 5
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
            }
          }
        }
      }
    }
  }
}

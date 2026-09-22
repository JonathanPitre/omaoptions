import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// OmaOptions — Logi Options-style panel for Logitech devices on Omarchy.
//
// bin/omaoptions (Python) does the work: `get` returns every device the engine
// has seen, with the slots and settings that device actually reports and its
// merged config; this panel edits a staged copy and hands the whole config
// back with `apply --json`. Battery/connection comes from `status`, which
// reads the engine's status file (no HID++ traffic from the bar).
Panel {
  id: root
  moduleName: "andreinita21.omaoptions"
  ipcTarget: "andreinita21.omaoptions"
  manageIpc: false

  readonly property string cli: Quickshell.env("HOME") + "/.config/omarchy/plugins/andreinita21.omaoptions/bin/omaoptions"
  readonly property string installCmd: "bash " + Quickshell.env("HOME") + "/.config/omarchy/plugins/andreinita21.omaoptions/install.sh"

  // ---- data from the backend ----
  property var config: null      // staged (editable) — {version, devices:{name:{settings,slots,custom}}}
  property var applied: null     // last known on-disk config
  property var deviceViews: []   // [{name, kind, group, available:[], slots:[], config:{}}]
  property var actions: []
  property var installed: ({ solaar: false, unit: false, voxtype: false })
  property var devices: []       // status: [{name, group, connected, idle, battery, charging, link}]
  property var service: ({ active: "unknown" })
  property string statusError: ""

  // ---- ui state ----
  property string tab: ""
  property string message: ""
  property bool messageIsError: false
  property bool applying: false
  property bool loaded: false

  readonly property bool dirty: config !== null && applied !== null && !Model.same(config, applied)
  readonly property bool setupNeeded: !(installed.solaar && installed.unit)
  readonly property bool serviceRunning: service && service.active === "active"
  readonly property int refreshIntervalSec: Math.max(30, parseInt(String(setting("refreshIntervalSec", 120)), 10) || 120)
  readonly property bool showPercentage: String(setting("showPercentage", "On")).toLowerCase() !== "off"
  readonly property string barText: Model.barLabel(devices, showPercentage)
  readonly property real openPanelIndicatorWidth: button.vertical ? 0 : button.glyphPaintedWidth
  readonly property real openPanelIndicatorHeight: button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool anyConnected: Model.anyConnected(devices)

  readonly property var currentView: {
    for (var i = 0; i < deviceViews.length; i++) if (deviceViews[i].name === tab) return deviceViews[i]
    return null
  }

  // ---- config access (per device) ----
  function devPath(name, sub) { return "devices." + name + "." + sub }
  // `sub` is "<section>.<key>" where the key itself may contain dots
  // (slots.gesture.tap, custom.key.0x108), so split at the first dot only.
  function splitSub(sub) {
    var i = String(sub).indexOf(".")
    return i < 0 ? [sub, ""] : [sub.slice(0, i), sub.slice(i + 1)]
  }
  function get(name, sub, fallback) {
    var parts = splitSub(sub)
    var dev = root.config && root.config.devices ? root.config.devices[name] : null
    var sec = dev ? dev[parts[0]] : null
    var v = sec && parts[1] in sec ? sec[parts[1]] : undefined
    if (v === undefined || v === null) {
      // fall back to the merged defaults the backend computed for this device
      for (var i = 0; i < deviceViews.length; i++) {
        if (deviceViews[i].name !== name) continue
        var vs = deviceViews[i].config ? deviceViews[i].config[parts[0]] : null
        var dv = vs && parts[1] in vs ? vs[parts[1]] : undefined
        return dv === undefined ? fallback : dv
      }
      return fallback
    }
    return v
  }
  function set(name, sub, value) {
    if (root.config === null) return
    if (Model.same(get(name, sub, undefined), value)) return
    var parts = splitSub(sub)
    var next = Model.clone(root.config)
    if (!next.devices) next.devices = {}
    if (!next.devices[name]) next.devices[name] = {}
    if (!next.devices[name][parts[0]] || typeof next.devices[name][parts[0]] !== "object") next.devices[name][parts[0]] = {}
    next.devices[name][parts[0]][parts[1]] = value
    root.config = next
  }
  function setNumber(name, sub, text) { var n = Number(text); if (isFinite(n)) set(name, sub, n) }
  function setNullable(name, sub, text) { set(name, sub, text === "unchanged" ? null : Number(text)) }
  function nullableValue(name, sub) {
    var v = get(name, sub, null)
    return v === null || v === undefined ? "unchanged" : String(v)
  }
  function slotValue(name, slot) { return String(get(name, "slots." + slot.id, slot.scope === "button" || slot.scope === "key" ? "default" : "none")) }
  function customFor(name, slotId) { return String(get(name, "custom." + slotId, "") || "") }
  function has(view, settingName) { return view && view.available && view.available.indexOf(settingName) >= 0 }
  function slotsFor(view, section) {
    var out = []
    if (!view) return out
    for (var i = 0; i < view.slots.length; i++) if (view.slots[i].section === section) out.push(view.slots[i])
    return out
  }
  function optionsFor(scope) { return Model.optionsFor(root.actions, scope) }
  function statusFor(name) {
    for (var i = 0; i < devices.length; i++) if (devices[i].name === name) return devices[i]
    return null
  }

  // ---- bar percentage toggle ----
  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: root.showPercentage ? "Off" : "On" })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  // ---- backend calls ----
  function reload() {
    if (!getProc.running) getProc.running = true
    refreshStatus()
  }
  function refreshStatus() {
    if (root.applying) return
    if (!statusProc.running) statusProc.running = true
  }
  function apply() {
    if (root.config === null || applyProc.running) return
    root.applying = true
    root.message = "Applying…"
    root.messageIsError = false
    applyProc.command = [root.cli, "apply", "--json", JSON.stringify(root.config)]
    applyProc.running = true
  }
  function revert() {
    if (root.applied !== null) root.config = Model.clone(root.applied)
    root.message = ""
  }
  function resetDefaults() {
    if (!root.currentView) return
    var next = Model.clone(root.config)
    if (next.devices) delete next.devices[root.currentView.name]
    root.config = next
    root.message = root.currentView.name + " reset to defaults — press Apply"
    root.messageIsError = false
  }
  function runInstaller() {
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.omaoptions-install", "bash", "-lc",
      root.installCmd + "; echo; read -rp 'Press Enter to close'"])
  }
  function runDoctor() {
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.omaoptions-doctor", "bash", "-lc",
      root.cli + " doctor | less -R"])
  }

  Process {
    id: getProc
    command: [root.cli, "get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          root.actions = d.actions || []
          root.deviceViews = d.devices || []
          root.installed = d.installed ? Object.assign({}, root.installed, d.installed) : root.installed
          root.applied = d.config
          if (root.config === null || !root.dirty) root.config = Model.clone(d.config)
          if (root.tab === "" && root.deviceViews.length > 0) root.tab = root.deviceViews[0].name
          root.loaded = true
        } catch (e) {
          root.message = "Could not read config: " + e
          root.messageIsError = true
        }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: statusProc
    command: [root.cli, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          var fresh = d.devices || []
          for (var i = 0; i < fresh.length; i++) {
            if (!fresh[i].connected || fresh[i].battery !== null) continue
            for (var j = 0; j < root.devices.length; j++) {
              if (root.devices[j].name === fresh[i].name && root.devices[j].battery !== null) {
                fresh[i].battery = root.devices[j].battery
                fresh[i].charging = root.devices[j].charging
              }
            }
          }
          root.devices = fresh
          root.service = d.service || ({ active: "unknown" })
          root.installed = d.installed ? Object.assign({}, root.installed, d.installed) : root.installed
          root.statusError = d.error || ""
        } catch (e) {
          root.statusError = "status failed: " + e
        }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { id: applyOut; waitForEnd: true }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.applying = false
      var d = null
      try { d = JSON.parse(applyOut.text) } catch (e) {}
      if (exitCode !== 0 && !d) {
        root.message = "Apply failed: " + (applyErr.text || ("exit " + exitCode)).trim()
        root.messageIsError = true
      } else if (d && d.warnings && d.warnings.length > 0) {
        root.message = d.warnings.join("\n")
        root.messageIsError = true
      } else {
        var notes = d && d.notes ? d.notes.filter(function(n) { return n.indexOf("wrote") !== 0 && n.indexOf("divert-keys") < 0 }) : []
        root.message = "Applied" + (notes.length ? " · " + notes.slice(-3).join(" · ") : "")
        root.messageIsError = false
      }
      root.applied = Model.clone(root.config)
      root.reload()
    }
  }

  Timer {
    interval: root.opened ? 30000 : root.refreshIntervalSec * 1000
    running: !root.applying
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Component.onCompleted: root.reload()

  onOpenedChanged: {
    if (opened) {
      root.message = ""
      root.reload()
    }
  }

  IpcHandler {
    target: "andreinita21.omaoptions"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function tab(name: string) { root.tab = name }
    function apply() { root.apply() }
    function refresh() { root.reload() }
    function togglePercentage() { root.togglePercentage() }
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------------- bar widget ----------------
  TextMetrics {
    id: barMetrics
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.bar.iconFont
    text: root.barText
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    slotSize: Math.max(Style.bar.iconSlot, Math.ceil(barMetrics.advanceWidth) + Style.space(20))
    tooltipText: Model.summary(root.devices)
    opacity: root.anyConnected ? 1.0 : 0.6
    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  // ---------------- popup ----------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(1000))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          PanelHero {
            width: parent.width
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            title: "OmaOptions"
            meta: Model.summary(root.devices)
            detail: root.dirty ? "UNSAVED CHANGES" : (root.serviceRunning ? "engine running" : (root.installed.unit ? "engine stopped" : ""))
            iconComponent: Component {
              Text {
                text: "󰍽"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Setup banner ----------
          Rectangle {
            visible: root.loaded && (root.setupNeeded || (root.installed.unit && !root.serviceRunning))
            width: parent.width
            implicitHeight: setupColumn.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            color: Util.alpha(Color.urgent, 0.10)
            border.color: Util.alpha(Color.urgent, 0.45)
            border.width: 1

            Column {
              id: setupColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: root.setupNeeded
                  ? "Setup needed: " + (!root.installed.solaar ? "Solaar missing. " : "") + (!root.installed.unit ? "engine service not installed. " : "") + "The installer needs your sudo password once."
                  : "The OmaOptions engine is not running, so gestures and remaps are off. Re-run the installer or check `omaoptions doctor`."
                color: Color.urgent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
              Button {
                text: "Run installer in a terminal"
                bordered: true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.runInstaller()
              }
            }
          }

          // ---------- Devices ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.devices
              delegate: Item {
                required property var modelData
                width: parent ? parent.width : 0
                implicitHeight: Math.max(devGlyph.implicitHeight, devName.implicitHeight) + Style.space(6)

                Text {
                  id: devGlyph
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.deviceGlyph(modelData.group)
                  color: root.bar.foreground
                  opacity: modelData.connected ? 1.0 : 0.45
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.icon
                }
                Text {
                  id: devName
                  anchors.left: devGlyph.right
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.name
                  color: root.bar.foreground
                  opacity: modelData.connected ? 1.0 : 0.55
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.deviceLine(modelData) + "  " + (modelData.connected ? Model.batteryGlyph(modelData.battery, modelData.charging) : "󰂑")
                  color: modelData.connected && modelData.battery !== null && modelData.battery <= 15 ? Color.urgent : root.bar.foreground
                  opacity: modelData.connected ? 0.9 : 0.5
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Text {
              visible: root.loaded && root.devices.length === 0
              width: parent.width
              text: root.serviceRunning ? "No Logitech device seen yet. Wake one up (move the mouse, press a key) and it appears here." : "No devices known."
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Text {
              visible: root.statusError !== "" && !root.setupNeeded
              width: parent.width
              text: root.statusError
              color: Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            ToggleRow {
              bar: root.bar
              label: "Battery percentages in the bar"
              description: "Right-click the bar icon toggles this too"
              checked: root.showPercentage
              onToggled: root.togglePercentage()
            }
          }

          PanelSeparator { foreground: root.bar.foreground }

          // ---------- Device tabs ----------
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.deviceViews
              delegate: Button {
                required property var modelData
                text: modelData.name
                iconText: Model.deviceGlyph(modelData.group)
                selected: root.tab === modelData.name
                bordered: true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.tab = modelData.name
              }
            }
          }

          Text {
            visible: !root.loaded
            text: "Loading…"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          // ================= current device =================
          Column {
            id: deviceColumn
            visible: root.loaded && root.currentView !== null
            width: parent.width
            spacing: Style.space(14)

            readonly property var view: root.currentView
            readonly property string dev: view ? view.name : ""

            Text {
              visible: !!deviceColumn.view && deviceColumn.view.unseen === true
              width: parent.width
              text: "This device has not been seen by the engine yet, so its options are unknown. Wake it up and reopen the panel."
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            // ---- Pointer & scroll (mice) ----
            Column {
              visible: root.has(deviceColumn.view, "dpi") || root.has(deviceColumn.view, "hires-smooth-resolution") || root.has(deviceColumn.view, "scroll-ratchet")
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader { text: "POINTER & SCROLL"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

              SettingRow {
                visible: root.has(deviceColumn.view, "dpi")
                bar: root.bar
                label: "Pointer speed"
                description: "DPI"
                value: String(root.get(deviceColumn.dev, "settings.dpi", 1000))
                options: Model.listOptions([400, 600, 800, 1000, 1200, 1600, 2000, 2400, 3200, 4000, 6000, 8000])
                onChanged: function(v) { root.setNumber(deviceColumn.dev, "settings.dpi", v) }
              }
              SettingRow {
                bar: root.bar
                label: "Vertical scroll speed"
                description: "Multiplier applied by Hyprland to the main wheel"
                value: root.nullableValue(deviceColumn.dev, "settings.verticalScroll")
                options: [
                  { value: "unchanged", label: "Same as global" },
                  { value: "0.05", label: "0.05×" }, { value: "0.1", label: "0.1×" }, { value: "0.15", label: "0.15×" },
                  { value: "0.2", label: "0.2×" }, { value: "0.3", label: "0.3×" }, { value: "0.5", label: "0.5×" },
                  { value: "0.7", label: "0.7×" }, { value: "1", label: "1×" }, { value: "1.5", label: "1.5×" },
                  { value: "2", label: "2×" }, { value: "3", label: "3×" }
                ]
                onChanged: function(v) { root.setNullable(deviceColumn.dev, "settings.verticalScroll", v) }
              }
              SettingRow {
                visible: root.has(deviceColumn.view, "thumb-scroll-mode")
                bar: root.bar
                label: "Horizontal scroll speed"
                description: "Thumb wheel, when set to scroll. Native = hardware speed"
                value: String(root.get(deviceColumn.dev, "settings.horizontalThreshold", 0))
                options: [
                  { value: "0", label: "Native" }, { value: "1", label: "Fastest" }, { value: "2", label: "Fast" },
                  { value: "4", label: "Normal" }, { value: "8", label: "Slow" }, { value: "16", label: "Slower" },
                  { value: "32", label: "Slowest" }
                ]
                onChanged: function(v) { root.setNumber(deviceColumn.dev, "settings.horizontalThreshold", v) }
              }
              ToggleRow {
                visible: root.has(deviceColumn.view, "hires-smooth-resolution")
                bar: root.bar
                label: "Smooth scrolling"
                description: "High-resolution wheel events"
                checked: root.get(deviceColumn.dev, "settings.hires", true) === true
                onToggled: root.set(deviceColumn.dev, "settings.hires", !(root.get(deviceColumn.dev, "settings.hires", true) === true))
              }
              ToggleRow {
                visible: root.has(deviceColumn.view, "hires-smooth-invert")
                bar: root.bar
                label: "Invert scroll wheel"
                checked: root.get(deviceColumn.dev, "settings.invertWheel", false) === true
                onToggled: root.set(deviceColumn.dev, "settings.invertWheel", !(root.get(deviceColumn.dev, "settings.invertWheel", false) === true))
              }
              ToggleRow {
                visible: root.has(deviceColumn.view, "scroll-ratchet")
                bar: root.bar
                label: "SmartShift"
                description: "Ratchet that frees up when you flick the wheel"
                checked: root.get(deviceColumn.dev, "settings.smartshiftOn", true) === true
                onToggled: root.set(deviceColumn.dev, "settings.smartshiftOn", !(root.get(deviceColumn.dev, "settings.smartshiftOn", true) === true))
              }
              SettingRow {
                visible: root.has(deviceColumn.view, "smart-shift") && root.get(deviceColumn.dev, "settings.smartshiftOn", true) === true
                bar: root.bar
                label: "SmartShift sensitivity"
                description: "Higher = flick harder to free-spin (50 never frees)"
                value: String(root.get(deviceColumn.dev, "settings.smartshift", 10))
                options: Model.numberOptions(5, 50, 5)
                onChanged: function(v) { root.setNumber(deviceColumn.dev, "settings.smartshift", v) }
              }
            }

            // ---- Gesture button ----
            Column {
              visible: root.slotsFor(deviceColumn.view, "Gesture button").length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader { text: "GESTURE BUTTON (THUMB)"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

              Repeater {
                model: root.slotsFor(deviceColumn.view, "Gesture button")
                delegate: slotEditor
              }
            }

            // ---- Thumb wheel ----
            Column {
              visible: root.slotsFor(deviceColumn.view, "Thumb wheel").length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader { text: "THUMB WHEEL"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

              ToggleRow {
                bar: root.bar
                label: "Invert thumb wheel"
                checked: root.get(deviceColumn.dev, "settings.invertThumb", false) === true
                onToggled: root.set(deviceColumn.dev, "settings.invertThumb", !(root.get(deviceColumn.dev, "settings.invertThumb", false) === true))
              }

              Repeater {
                model: root.slotsFor(deviceColumn.view, "Thumb wheel")
                delegate: slotEditor
              }
            }

            // ---- Buttons (mice) ----
            Column {
              visible: root.slotsFor(deviceColumn.view, "Buttons").length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader { text: "BUTTONS"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

              Repeater {
                model: root.slotsFor(deviceColumn.view, "Buttons")
                delegate: slotEditor
              }

              Text {
                width: parent.width
                text: "“Device default” keeps the button's built-in behaviour."
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }

            // ---- Layout (keyboards) ----
            Column {
              visible: root.has(deviceColumn.view, "fn-swap") || root.has(deviceColumn.view, "multiplatform")
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader { text: "LAYOUT"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

              SettingRow {
                visible: root.has(deviceColumn.view, "fn-swap")
                bar: root.bar
                label: "Top row without fn"
                description: "What F1–F12 send on a plain press"
                value: String(root.get(deviceColumn.dev, "settings.topRow", "media"))
                options: [
                  { value: "fkeys", label: "F1–F12" },
                  { value: "media", label: "Media / brightness" },
                  { value: "unchanged", label: "Leave as is" }
                ]
                onChanged: function(v) { root.set(deviceColumn.dev, "settings.topRow", v) }
              }
              SettingRow {
                visible: root.has(deviceColumn.view, "multiplatform")
                bar: root.bar
                label: "OS layout"
                description: "Cmd/Option vs Alt/Super positions (fn+O / fn+P)"
                value: String(root.get(deviceColumn.dev, "settings.layout", "unchanged"))
                options: [
                  { value: "unchanged", label: "Leave as is" },
                  { value: "Linux", label: "Linux" },
                  { value: "MacOS", label: "macOS (Cmd = Super)" },
                  { value: "Windows", label: "Windows" },
                  { value: "iOS", label: "iOS" },
                  { value: "Android", label: "Android" },
                  { value: "Chrome", label: "ChromeOS" }
                ]
                onChanged: function(v) { root.set(deviceColumn.dev, "settings.layout", v) }
              }
            }

            // ---- Backlight (keyboards) ----
            Column {
              visible: root.has(deviceColumn.view, "backlight")
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader { text: "BACKLIGHT"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

              SettingRow {
                bar: root.bar
                label: "Mode"
                value: String(root.get(deviceColumn.dev, "settings.backlightMode", "unchanged"))
                options: [
                  { value: "unchanged", label: "Leave as is" },
                  { value: "Automatic", label: "Automatic (ambient)" },
                  { value: "Manual", label: "Manual level" },
                  { value: "Disabled", label: "Off" }
                ]
                onChanged: function(v) { root.set(deviceColumn.dev, "settings.backlightMode", v) }
              }
              SettingRow {
                visible: root.has(deviceColumn.view, "backlight_level") && root.get(deviceColumn.dev, "settings.backlightMode", "unchanged") === "Manual"
                bar: root.bar
                label: "Brightness level"
                value: String(root.get(deviceColumn.dev, "settings.backlightLevel", 2))
                options: Model.listOptions([0, 5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 98])
                onChanged: function(v) { root.setNumber(deviceColumn.dev, "settings.backlightLevel", v) }
              }
              SettingRow {
                visible: root.has(deviceColumn.view, "backlight_duration_hands_out") && root.get(deviceColumn.dev, "settings.backlightMode", "unchanged") !== "unchanged"
                bar: root.bar
                label: "Fade out, hands away"
                value: root.nullableValue(deviceColumn.dev, "settings.fadeHandsOut")
                options: Model.listOptions([5, 10, 15, 30, 60, 120, 300, 600], " s", [{ value: "unchanged", label: "Leave as is" }])
                onChanged: function(v) { root.setNullable(deviceColumn.dev, "settings.fadeHandsOut", v) }
              }
              SettingRow {
                visible: root.has(deviceColumn.view, "backlight_duration_hands_in") && root.get(deviceColumn.dev, "settings.backlightMode", "unchanged") !== "unchanged"
                bar: root.bar
                label: "Fade out, hands near"
                value: root.nullableValue(deviceColumn.dev, "settings.fadeHandsIn")
                options: Model.listOptions([5, 10, 15, 30, 60, 120, 300, 600], " s", [{ value: "unchanged", label: "Leave as is" }])
                onChanged: function(v) { root.setNullable(deviceColumn.dev, "settings.fadeHandsIn", v) }
              }
              SettingRow {
                visible: root.has(deviceColumn.view, "backlight_duration_powered") && root.get(deviceColumn.dev, "settings.backlightMode", "unchanged") !== "unchanged"
                bar: root.bar
                label: "Fade out, on power"
                value: root.nullableValue(deviceColumn.dev, "settings.fadePowered")
                options: Model.listOptions([5, 10, 15, 30, 60, 120, 300, 600], " s", [{ value: "unchanged", label: "Leave as is" }])
                onChanged: function(v) { root.setNullable(deviceColumn.dev, "settings.fadePowered", v) }
              }
            }

            // ---- Keys (keyboards) ----
            Column {
              visible: root.slotsFor(deviceColumn.view, "Keys").length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader { text: "F-ROW & SPECIAL KEYS"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

              Repeater {
                model: root.slotsFor(deviceColumn.view, "Keys")
                delegate: slotEditor
              }

              Text {
                width: parent.width
                text: "Only keys the keyboard's firmware can hand over are listed (Easy-Switch keys never are). “Device default” keeps a key's built-in function."
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }
          }

          PanelSeparator { visible: root.loaded; foreground: root.bar.foreground }

          // ---------- Footer ----------
          Column {
            visible: root.loaded
            width: parent.width
            spacing: Style.space(8)

            Text {
              visible: root.message !== ""
              width: parent.width
              text: root.message
              color: root.messageIsError ? Color.urgent : root.bar.foreground
              opacity: root.messageIsError ? 1.0 : 0.75
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Row {
              spacing: Style.space(6)
              Button {
                text: root.applying ? "Applying…" : "Apply"
                iconText: "󰄬"
                bordered: true
                enabled: root.dirty && !root.applying && root.installed.solaar
                opacity: enabled ? 1.0 : 0.5
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.apply()
              }
              Button {
                text: "Revert"
                bordered: true
                enabled: root.dirty && !root.applying
                opacity: enabled ? 1.0 : 0.5
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.revert()
              }
              Button {
                text: "Defaults"
                bordered: true
                tooltipText: "Reset this device to the built-in defaults"
                enabled: !root.applying && root.currentView !== null
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.resetDefaults()
              }
              Button {
                text: "Doctor"
                iconText: "󰩺"
                bordered: true
                tooltipText: "Open diagnostics in a terminal"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.runDoctor()
              }
            }
          }
        }
      }
    }
  }

  // One remappable slot of the current device.
  Component {
    id: slotEditor

    Column {
      required property var modelData
      width: parent ? parent.width : 0
      spacing: Style.space(4)

      Dropdown {
        width: parent.width
        label: modelData.label
        value: root.slotValue(deviceColumn.dev, modelData)
        options: root.optionsFor(modelData.scope)
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        onChanged: function(v) { root.set(deviceColumn.dev, "slots." + modelData.id, v) }
      }

      TextField {
        visible: root.slotValue(deviceColumn.dev, modelData) === "custom"
        width: parent.width
        placeholderText: "shell command, e.g. hyprctl dispatch 'hl.dsp.window.close()'"
        text: root.customFor(deviceColumn.dev, modelData.id)
        foreground: root.bar.foreground
        font.family: root.bar.fontFamily
        onTextEdited: root.set(deviceColumn.dev, "custom." + modelData.id, text)
      }
    }
  }
}

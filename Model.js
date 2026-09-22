// Pure helpers for Panel.qml — no QML objects in here so they stay testable.
.pragma library

function clone(obj) {
  return obj === undefined ? undefined : JSON.parse(JSON.stringify(obj))
}

function getPath(obj, dotted, fallback) {
  var node = obj
  var parts = String(dotted).split(".")
  for (var i = 0; i < parts.length; i++) {
    if (node === null || node === undefined || typeof node !== "object" || !(parts[i] in node)) return fallback
    node = node[parts[i]]
  }
  return node === undefined ? fallback : node
}

// Returns a fresh copy with the value set, so QML bindings re-evaluate.
function setPath(obj, dotted, value) {
  var out = clone(obj) || {}
  var node = out
  var parts = String(dotted).split(".")
  for (var i = 0; i < parts.length - 1; i++) {
    if (node[parts[i]] === null || typeof node[parts[i]] !== "object") node[parts[i]] = {}
    node = node[parts[i]]
  }
  node[parts[parts.length - 1]] = value
  return out
}

function same(a, b) {
  return JSON.stringify(a) === JSON.stringify(b)
}

// Dropdown options for a slot scope, grouped by catalog group order.
function optionsFor(actions, scope) {
  var out = []
  for (var i = 0; i < actions.length; i++) {
    var a = actions[i]
    if (!a.scopes || a.scopes.indexOf(scope) < 0) continue
    out.push({ value: a.id, label: a.group === "General" || a.group === "Scroll" ? a.label : a.group + " · " + a.label })
  }
  return out
}

function actionLabel(actions, id) {
  for (var i = 0; i < actions.length; i++) if (actions[i].id === id) return actions[i].label
  return id
}

function slotsFor(slots, tab, section) {
  var out = []
  for (var i = 0; i < slots.length; i++) {
    if (slots[i].tab === tab && (!section || slots[i].section === section)) out.push(slots[i])
  }
  return out
}

// Keyboard slots whose control ID the device actually reported (if we have a
// discovery result); otherwise all of them.
function filterDiscovered(slots, discovered, deviceName) {
  if (!discovered || !discovered.devices) return slots
  var cids = null
  for (var i = 0; i < discovered.devices.length; i++) {
    var d = discovered.devices[i]
    if (d.name && deviceName && d.name.toLowerCase() === deviceName.toLowerCase() && d.keys && d.keys.length > 0) {
      // Prefer the keys Solaar flags as divertable; fall back to every key it
      // listed when the flags are missing.
      var flagged = d.keys.filter(function(k) { return k.divertable === true })
      var pool = flagged.length ? flagged : d.keys
      cids = {}
      for (var k = 0; k < pool.length; k++) if (pool[k].cid !== null && pool[k].cid !== undefined) cids[pool[k].cid] = true
    }
  }
  if (!cids) return slots
  var out = []
  for (var s = 0; s < slots.length; s++) {
    if (slots[s].cid === undefined || cids[slots[s].cid]) out.push(slots[s])
  }
  return out
}

function batteryGlyph(pct, charging) {
  if (pct === null || pct === undefined) return "󰂑"
  if (charging) return "󰂄"
  if (pct >= 95) return "󰁹"
  if (pct >= 85) return "󰂂"
  if (pct >= 75) return "󰂁"
  if (pct >= 65) return "󰂀"
  if (pct >= 55) return "󰁿"
  if (pct >= 45) return "󰁾"
  if (pct >= 35) return "󰁽"
  if (pct >= 25) return "󰁼"
  if (pct >= 15) return "󰁻"
  if (pct >= 5) return "󰁺"
  return "󰂃"
}

function deviceGlyph(group) {
  return group === "keyboard" ? "󰌌" : "󰍽"
}

function linkLabel(link) {
  if (link === "receiver") return "Bolt"
  if (link === "bluetooth") return "Bluetooth"
  if (link === "usb") return "USB"
  return ""
}

function deviceLine(d) {
  if (!d) return ""
  if (!d.connected) return "Offline"
  var parts = []
  if (d.battery !== null && d.battery !== undefined) parts.push(d.battery + "%")
  if (d.charging) parts.push("charging")
  var link = linkLabel(d.link)
  if (link) parts.push(link)
  if (d.idle) parts.push("sleeping")
  return parts.length ? parts.join(" · ") : "Connected"
}

function summary(devices) {
  if (!devices || devices.length === 0) return "No devices"
  var parts = []
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    var name = d.name || (d.group === "keyboard" ? "Keyboard" : "Mouse")
    if (!d.connected) parts.push(name + " offline")
    else if (d.battery !== null && d.battery !== undefined) parts.push(name + " " + d.battery + "%")
    else parts.push(name + " on")
  }
  return parts.join(" · ")
}

function lowestBattery(devices) {
  var low = null
  for (var i = 0; i < (devices || []).length; i++) {
    var d = devices[i]
    if (d.connected && d.battery !== null && d.battery !== undefined && (low === null || d.battery < low)) low = d.battery
  }
  return low
}

function anyConnected(devices) {
  for (var i = 0; i < (devices || []).length; i++) if (devices[i].connected) return true
  return false
}

// Options for a numeric dropdown: [{value, label}] from min..max by step.
function numberOptions(min, max, step, suffix, extra) {
  var out = extra ? extra.slice() : []
  for (var v = min; v <= max; v += step) out.push({ value: String(v), label: String(v) + (suffix || "") })
  return out
}

function listOptions(values, suffix, extra) {
  var out = extra ? extra.slice() : []
  for (var i = 0; i < values.length; i++) out.push({ value: String(values[i]), label: String(values[i]) + (suffix || "") })
  return out
}

// Bar label: "󰍽 80%  󰌌 100%" — offline devices get the crossed-out glyph and
// no number.
// Bar label: one glyph per known device, mice first, e.g. "󰍽 80%  󰌌 100%".
// Offline devices get the crossed-out glyph and no number. With nothing known
// yet a single mouse glyph stands in.
function barLabel(devices, showPercentage) {
  var list = (devices || []).slice().sort(function(a, b) {
    var ga = a.group === "keyboard" ? 1 : 0, gb = b.group === "keyboard" ? 1 : 0
    return ga - gb
  })
  if (list.length === 0) return "󰍽"
  var parts = []
  for (var i = 0; i < list.length; i++) {
    var d = list[i]
    var glyph = d.group === "keyboard" ? (d.connected ? "󰌌" : "󰌐") : (d.connected ? "󰍽" : "󰍾")
    var txt = glyph
    if (showPercentage && d.connected && d.battery !== null && d.battery !== undefined) txt += " " + d.battery + "%"
    parts.push(txt)
  }
  return parts.join("  ")
}

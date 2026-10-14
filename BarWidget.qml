import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// System Diagnostics -- the bar half of the plugin.
//
// Owns the diagnostic icon and the popup host, and nothing else: the scan
// itself and every decision about what a finding means live in bin/diagnose.sh
// and Model.js. This file only decides what colour to paint and when to open.
BarWidget {
  id: root
  moduleName: "angelherman.system-diagnostics"

  // ---- panel wiring. `Panel.qml` is a separate component loaded here so the
  //      heavy popup is not built until the widget exists.
  readonly property var panel: panelLoader.item
  readonly property bool opened: panel ? panel.opened === true : false

  // ---- health, read off the panel's last scan.
  readonly property string healthState: panel ? panel.state : "unknown"

  readonly property color okColor: root.themeOk
  readonly property color attentionColor: root.bar ? root.bar.barForeground : Color.accent
  readonly property color problemColor: root.bar ? root.bar.urgent : Color.urgent

  // A green that is not part of the theme, chosen to stay legible on both the
  // light and dark bar: the palette carries red (urgent) and an accent, but no
  // "good" colour, and "all clear" needs to be distinguishable at a glance.
  readonly property color themeOk: bar && bar.barForeground
    ? Qt.tint(bar.barForeground, Qt.rgba(0.30, 0.72, 0.36, 0.85))
    : "#6cbf6c"

  function dotColor(i) {
    if (i === 0) return root.problemColor
    if (i === 1) return root.attentionColor
    return root.okColor
  }
  function activeDot() {
    var s = root.healthState
    if (s === "problem") return 0
    if (s === "attention" || s === "unknown") return 1
    return 2
  }

  // ---- open/close shape the bar's popout coordinator probes for (same
  //      contract as the first-party widgets and Cronos-Calendar).
  function open() { if (root.panel) root.panel.open() }
  function close() { if (root.panel) root.panel.close() }
  function togglePanel() { if (root.panel) root.panel.toggle() }
  function refresh(mode) { if (root.panel) root.panel.refresh(mode || "quick", true) }

  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (root.panel) root.panel.closeForPopoutSwitch() }

  function injectPanel() {
    var t = panelLoader.item
    if (!t) return
    if ("bar" in t) t.bar = root.bar
    if ("settings" in t) t.settings = root.settings
    if ("anchorItem" in t) t.anchorItem = button
    if ("hostWidget" in t) t.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: Style.space(28)
    tooltipText: "System Diagnostics — " + Model.stateLabel(root.healthState) +
      "\nLeft-click: open   ·   Right-click: quick scan   ·   Middle-click: full scan"

    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh("quick")
      else if (b === Qt.MiddleButton) root.refresh("full")
      else root.togglePanel()
    }

    // Font Awesome stethoscope glyph, present in Omarchy's Nerd Font. Keep its
    // color tied to the scan verdict so the icon remains a status indicator.
    Text {
      anchors.centerIn: parent
      text: "\uf0f1"
      color: root.dotColor(root.activeDot())
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.icon
      renderType: Text.NativeRendering

      Behavior on color {
        ColorAnimation { duration: 160 }
      }
    }
  }

  IpcHandler {
    target: "angelherman.system-diagnostics"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refresh("quick") }
    function scan(): void { root.refresh("quick") }
    function full(): void { root.refresh("full") }
  }
}

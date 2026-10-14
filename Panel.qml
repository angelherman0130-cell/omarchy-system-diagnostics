import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// System Diagnostics -- the popup half of the plugin.
//
// A renderer over the JSON that bin/diagnose.sh emits. Every classification and
// every report line comes from Model.js, so the panel, the clipboard report and
// the saved files can never disagree about what a scan found.
Panel {
  id: root
  moduleName: "angelherman.system-diagnostics"
  ipcTarget: "angelherman.system-diagnostics"
  // The bar widget owns the single IpcHandler for this target; this panel is
  // loaded by it, so it must not register a second one.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ------------------------------------------------------------ scan state
  property var scan: null
  property bool scanning: false
  property string lastError: ""
  property string lastMode: "quick"
  property string toast: ""
  property bool showAll: false
  // "save-md" | "save-json" | "send-ai" | "" -- what to do once the pending
  // text has been written to disk.
  property string pendingAction: ""
  property string pendingPath: ""

  readonly property var checks: scan && Array.isArray(scan.checks) ? scan.checks : []
  readonly property string state: Model.overallState(checks)
  readonly property var totals: Model.counts(checks)
  readonly property var rows: Model.findingRows(checks, showAll)
  readonly property bool ready: scan !== null
  readonly property int issueCount: Model.thingsToFix(checks).length

  // ------------------------------------------------------------ a live "now"
  // Date.now() is not a QML dependency, so a binding on it would freeze once
  // the panel stopped changing and the age readout would stop ageing.
  property int clockSec: Math.floor(Date.now() / 1000)
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: root.clockSec = Math.floor(Date.now() / 1000)
  }
  readonly property string ageText: scan ? Model.fmtAge(scan.ts, clockSec) : "never"

  // ------------------------------------------------------------ colours
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color accent: bar ? bar.urgent : Color.urgent
  readonly property color muted: Color.muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function statusColor(status) {
    if (status === "problem") return root.accent
    if (status === "attention") return root.foreground
    return Qt.darker(root.foreground, 1.4)
  }

  // ------------------------------------------------------------ paths + env
  function localPath(relative) {
    var u = Qt.resolvedUrl(relative).toString()
    return u.indexOf("file://") === 0 ? u.slice(7) : u
  }
  readonly property string diagnosePath: localPath("bin/diagnose.sh")
  readonly property string stateDir: (Quickshell.env("HOME") || "") + "/.local/state/system-diagnostics"

  // The scan needs more than PATH: hyprctl talks to the compositor through the
  // socket named by HYPRLAND_INSTANCE_SIGNATURE, and wl-copy needs
  // WAYLAND_DISPLAY. Everything else is dropped, so nothing inherited from the
  // long-lived shell can influence a probe. (Same posture as OmaDoctor.)
  function trustedEnv() {
    return {
      "PATH": "/usr/bin:/bin",
      "HOME": Quickshell.env("HOME"),
      "LC_ALL": "C",
      "HYPRLAND_INSTANCE_SIGNATURE": Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "",
      "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR") || ""
    }
  }
  function clipboardEnv() {
    var env = trustedEnv()
    env.WAYLAND_DISPLAY = Quickshell.env("WAYLAND_DISPLAY") || ""
    return env
  }

  // ------------------------------------------------------------ default agent
  // Which AI agent will the report be sent to? Omarchy already knows: the user
  // picks one with `omarchy default agent <name>`, and reading it back through
  // that same CLI is the STABLE interface. The plugin therefore never hardcodes
  // an agent (opencode, claude, codex, gemini, ...) and never guesses from a
  // list of installed CLIs -- it asks Omarchy, exactly as `omarchy agent` does,
  // so whatever the user chose is what opens.
  //
  // The probe runs with the inherited environment (no clearEnvironment):
  // omarchy-default-agent reads $HOME/.config and prints the slug, or prints
  // nothing and exits 0 when no agent is chosen.
  property string defaultAgent: ""

  function detectAgent() {
    if (agentDetectProc.running) return
    agentDetectProc.command = ["/usr/bin/omarchy", "default", "agent"]
    agentDetectProc.running = true
  }

  Component.onCompleted: root.detectAgent()
  // Re-check every time the popup opens: the user may have changed the default
  // with `omarchy default agent` since the shell started.
  onOpenedChanged: if (root.opened) root.detectAgent()

  Process {
    id: agentDetectProc
    stdout: StdioCollector {
      // `text` here is a property (StdioCollector), not the FileView `text()`.
      waitForEnd: true
      onStreamFinished: root.defaultAgent = String(text).trim()
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.defaultAgent = ""
    }
  }

  // ------------------------------------------------------------ scanning
  // doctor.sh runs its sections behind per-section deadlines; the outer budget
  // here only needs to be the sum of them plus slack, so it is generous. Quick
  // sections total well under a minute; full adds network + graphics.
  readonly property int budgetMs: lastMode === "full" ? 180000 : 100000

  function refresh(mode, userInitiated) {
    if (scanProc.running) return
    root.lastMode = mode || "quick"
    root.scanning = true
    root.lastError = ""
    root.toast = ""
    scanProc.finished = false
    scanProc.stdoutDone = false
    scanProc.stderrDone = false
    scanProc.stdoutText = ""
    scanProc.stderrText = ""
    scanProc.command = ["/bin/sh", root.diagnosePath, root.lastMode]
    scanProc.running = true
    watchTimer.restart()
  }

  // Called by scanProc when both streams have drained and the process exited.
  function onScanFinished(raw, exitCode, errText) {
    root.scanning = false
    watchTimer.stop()
    var doc = Model.parseScan(raw)
    if (doc) {
      root.scan = doc
      root.lastError = ""
      return
    }
    // A scan that produced no parseable document is an error, not an empty
    // result: never overwrite a previous good scan with nothing.
    root.lastError = errText && errText.trim() !== ""
      ? errText.trim().split("\n")[0]
      : ("the scan produced no readable output (exit " + exitCode + ")")
    console.warn("System-Diagnostics: scan failed:", root.lastError)
  }

  Timer {
    id: watchTimer
    interval: root.budgetMs
    repeat: false
    onTriggered: {
      if (scanProc.running) {
        scanProc.running = false
        root.scanning = false
        root.lastError = "the scan exceeded its time budget and was stopped"
      }
    }
  }

  // ------------------------------------------------------------ clipboard
  function copyText(text) {
    if (copyProc.running) { root.toast = "Clipboard is busy — try again."; return false }
    copyProc.pending = String(text || "")
    copyProc.running = true
    return true
  }

  function copyForAi() {
    if (!root.ready) return
    if (root.copyText(Model.buildPrompt(root.scan)))
      root.toast = "Prompt copied — paste it into your AI assistant."
  }

  // ------------------------------------------------------------ save / send
  function saveText(text, suffix, action) {
    if (teeProc.running) { root.toast = "Still writing the previous file…"; return }
    var ts = root.scan && root.scan.ts ? root.scan.ts : Math.floor(Date.now() / 1000)
    root.pendingPath = root.stateDir + "/report-" + ts + suffix
    root.pendingAction = action || ""
    teeProc.pending = String(text || "")
    teeProc.command = ["/usr/bin/tee", root.pendingPath]
    teeProc.running = true
  }

  function saveMarkdown() {
    if (!root.ready) return
    root.saveText(Model.buildReport(root.scan, { fullDetail: false }), ".md", "save-md")
  }
  function saveJson() {
    if (!root.ready) return
    root.saveText(Model.buildJson(root.scan), ".json", "save-json")
  }

  // Writes the AI prompt to disk, then (once written) launches Omarchy's
  // default coding agent on it. The report travels as a FILE PATH, never as an
  // argv entry, so a multi-kilobyte report never floods a process list.
  function sendToAi() {
    if (!root.ready) return
    if (root.defaultAgent === "") {
      // No agent chosen: never do nothing quietly. The prompt still works when
      // pasted into any assistant, so hand it over by clipboard and say how to
      // set a default.
      if (root.copyText(Model.buildPrompt(root.scan)))
        root.toast = "No default agent set — copied the prompt instead. " +
          "Set one with: omarchy default agent <name>"
      else
        root.toast = "No default agent set, and the clipboard is busy."
      return
    }
    root.saveText(Model.buildPrompt(root.scan), "-prompt.md", "send-ai")
  }

  // Launches the agent through Omarchy itself: `omarchy agent prompt` resolves
  // the user's chosen agent, applies that agent's non-interactive flags, and
  // opens it in a terminal window (via uwsm-app / xdg-terminal-exec).
  //
  // NOT --inline. --inline execs the agent in the CURRENT tty, and a click in a
  // GUI has no tty, so the agent ran with no terminal and nothing ever
  // appeared. The terminal-launching path is the one a GUI action wants.
  function launchAgent(path) {
    var msg = "Read the Omarchy system diagnostic report at \"" + path +
      "\" and help me resolve the findings it lists."
    agentProc.command = ["/usr/bin/omarchy", "agent", "prompt", msg]
    agentProc.running = true
    root.toast = "Opening " + root.defaultAgent + " with the report…"
  }

  function toggleShowAll() { root.showAll = !root.showAll }

  // ------------------------------------------------------------ process: scan
  Process {
    id: scanProc
    clearEnvironment: true
    environment: root.trustedEnv()
    property string stdoutText: ""
    property string stderrText: ""
    property bool finished: false
    property bool stdoutDone: false
    property bool stderrDone: false
    property int exitCode: 0

    // Finish only once BOTH collectors have delivered EOF and the process has
    // exited; whichever of the three arrives last wins. Finishing early handed
    // onScanFinished whatever the other stream happened to hold -- often the
    // previous run's text, since a Process keeps its collected streams.
    function tryFinish() {
      if (scanProc.finished) return
      if (!scanProc.stdoutDone || !scanProc.stderrDone) return
      scanProc.finished = true
      root.onScanFinished(scanProc.stdoutText, scanProc.exitCode, scanProc.stderrText)
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        scanProc.stdoutText = text
        scanProc.stdoutDone = true
        scanProc.tryFinish()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        scanProc.stderrText = text
        scanProc.stderrDone = true
        scanProc.tryFinish()
      }
    }
    onExited: function(exitCode) {
      scanProc.exitCode = exitCode
      // A collector that never fires must not strand the scan on "scanning…".
      scanProc.stdoutDone = true
      scanProc.stderrDone = true
      scanProc.tryFinish()
    }
  }

  // ------------------------------------------------------------ process: copy
  Process {
    id: copyProc
    clearEnvironment: true
    environment: root.clipboardEnv()
    stdinEnabled: true
    command: ["/usr/bin/wl-copy"]
    property string pending: ""
    onStarted: {
      if (copyProc.pending !== "") copyProc.write(copyProc.pending)
      // wl-copy reads stdin until EOF, so the write end must close on the same
      // tick or the process never exits and the clipboard never updates.
      copyProc.stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (copyProc.stdinEnabled === false) copyProc.stdinEnabled = true
      copyProc.pending = ""
      if (exitCode !== 0) root.toast = "Could not copy — wl-copy exited " + exitCode + "."
    }
  }

  // ------------------------------------------------------------ process: tee
  Process {
    id: teeProc
    clearEnvironment: true
    environment: root.trustedEnv()
    stdinEnabled: true
    property string pending: ""
    onStarted: {
      if (teeProc.pending !== "") teeProc.write(teeProc.pending)
      teeProc.stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (teeProc.stdinEnabled === false) teeProc.stdinEnabled = true
      teeProc.pending = ""
      var path = root.pendingPath
      var action = root.pendingAction
      root.pendingAction = ""
      if (exitCode !== 0) {
        root.toast = "Could not write " + path + " (exit " + exitCode + ")."
        return
      }
      if (action === "send-ai") root.launchAgent(path)
      else root.toast = "Saved " + path
    }
  }

  // ------------------------------------------------------------ process: agent
  // Deliberately does NOT clearEnvironment. The terminal launcher (uwsm-app /
  // xdg-terminal-exec) and the agent binary live in the user's real session:
  // they need WAYLAND_DISPLAY and DBUS, and the PATH that finds an agent
  // installed under ~/.local/bin, a nix profile or mise shims -- none of which
  // the scan's hardened PATH=/usr/bin:/bin can see. This is not a security
  // boundary: it runs the user's own agent only after an explicit click.
  Process {
    id: agentProc
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.toast = "Could not launch " + root.defaultAgent +
          " (exit " + exitCode + "). Is it still installed?"
    }
  }

  // ------------------------------------------------------------ UI
  readonly property string headline: {
    if (!root.ready) return "No scan yet"
    if (root.state === "ok" || root.state === "info") return "All checks passed"
    return Model.pluralize(root.issueCount, "finding") + " need review"
  }
  readonly property string breakdown: root.ready
    ? root.totals.total + " checks · " + root.totals.problem + " problem · " +
      root.totals.attention + " attention · " + root.totals.unknown + " unknown · " +
      root.totals.ok + " ok"
    : "Run a scan to see the machine's health."

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.refresh(root.lastMode, true)
      onTextKey: function(t) {
        if (t === "q" || t === "Q") root.close()
        else if (t === "r" || t === "R") root.refresh("quick", true)
        else if (t === "f" || t === "F") root.refresh("full", true)
        else if (t === "a" || t === "A") root.copyForAi()
        else if (t === "s" || t === "S") root.saveMarkdown()
        else if (t === "d" || t === "D") root.toggleShowAll()
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.spacing.md

          // ---- hero
          Column {
            width: parent.width
            spacing: Style.spacing.xs

            Text {
              width: parent.width
              text: root.headline
              color: root.state === "problem" ? root.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.WordWrap
            }
            Text {
              width: parent.width
              text: root.breakdown
              color: Qt.alpha(root.foreground, 0.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Text {
              width: parent.width
              visible: root.scan && root.scan.host
              text: root.scan && root.scan.host ? Model.hostLine(root.scan.host) : ""
              color: Qt.alpha(root.foreground, 0.55)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Text {
              width: parent.width
              visible: root.ready
              text: "Last " + root.lastMode + " scan: " + root.ageText
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: parent.width
              text: root.defaultAgent === ""
                ? "No default AI agent — set one with: omarchy default agent <name>"
                : "Default AI agent: " + root.defaultAgent
              color: root.defaultAgent === ""
                ? Qt.alpha(root.foreground, 0.55)
                : Qt.darker(root.foreground, 1.2)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Text {
              width: parent.width
              visible: root.scanning
              text: "Scanning (" + root.lastMode + ")…"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: parent.width
              visible: root.lastError !== ""
              text: "Scan error: " + root.lastError
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ---- action buttons
          Row {
            id: actionRow
            width: parent.width
            spacing: Style.spacing.sm

            Button {
              iconText: "\u{F021}"      // refresh
              text: "Quick scan"
              tooltipText: "Re-run the quick (local) scan"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              background: Util.alpha(root.accent, 0.10)
              enabled: !root.scanning
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX - Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY - Style.space(1)
              onClicked: root.refresh("quick", true)
            }
            Button {
              iconText: "\u{F0C1}"      // filter/scan full
              text: "Full scan"
              tooltipText: "Deep scan, including network, GPU and SMART"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              enabled: !root.scanning
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX - Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY - Style.space(1)
              onClicked: root.refresh("full", true)
            }
          }

          Row {
            id: exportRow
            width: parent.width
            spacing: Style.spacing.sm

            Button {
              iconText: "\u{F0125}"     // clipboard
              text: "Copy for AI"
              tooltipText: "Copy a ready-to-paste prompt with the full report"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              enabled: root.ready
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX - Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY - Style.space(1)
              onClicked: root.copyForAi()
            }
            Button {
              iconText: "\u{F0219}"     // save
              text: "Save .md"
              tooltipText: "Save the Markdown report under ~/.local/state/system-diagnostics"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              enabled: root.ready
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX - Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY - Style.space(1)
              onClicked: root.saveMarkdown()
            }
            Button {
              iconText: "\u{F0219}"
              text: "Save .json"
              tooltipText: "Save the raw scan as JSON"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              enabled: root.ready
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX - Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY - Style.space(1)
              onClicked: root.saveJson()
            }
            Button {
              iconText: "\u{F06A9}"     // robot / agent
              text: root.defaultAgent === "" ? "Send to AI" : "Send to " + root.defaultAgent
              tooltipText: root.defaultAgent === ""
                ? "No default agent set — the prompt will be copied instead. " +
                  "Set one with: omarchy default agent <name>"
                : "Open " + root.defaultAgent + " with the report (omarchy agent prompt)"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              enabled: root.ready
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX - Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY - Style.space(1)
              onClicked: root.sendToAi()
            }
          }

          Text {
            width: parent.width
            visible: root.toast !== ""
            text: root.toast
            color: Qt.alpha(root.foreground, 0.75)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ---- findings
          Text {
            width: parent.width
            visible: root.ready && root.rows.length === 0
            text: "Nothing to review. Use “Show all checks” to see every test that ran."
            color: Qt.alpha(root.foreground, 0.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.rows

            delegate: Column {
              id: rowItem
              required property var modelData
              width: column.width
              spacing: Style.spacing.xs

              // Section header.
              Text {
                width: parent.width
                visible: rowItem.modelData.kind === "header"
                text: visible ? (rowItem.modelData.label + "  (" + rowItem.modelData.count + ")") : ""
                color: Qt.alpha(root.foreground, 0.75)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                font.capitalization: Font.AllUppercase
                topPadding: Style.spacing.sm
              }

              // Finding.
              Column {
                id: finding
                width: parent.width
                spacing: Style.space(2)
                visible: rowItem.modelData.kind === "check"
                readonly property var chk: rowItem.modelData.check

                Row {
                  width: parent.width
                  spacing: Style.spacing.xs

                  Text {
                    text: Model.statusGlyph(finding.chk.status)
                    color: root.statusColor(finding.chk.status)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width - Style.space(16)
                    text: finding.chk.title +
                      (finding.chk.value ? "  —  " + finding.chk.value : "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    wrapMode: Text.WordWrap
                  }
                }
                Text {
                  width: parent.width
                  visible: finding.chk.detail !== ""
                  text: finding.chk.detail
                  color: Qt.alpha(root.foreground, 0.72)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  leftPadding: Style.space(12)
                }
                Text {
                  width: parent.width
                  visible: finding.chk.suggestion !== ""
                  text: "→ " + finding.chk.suggestion
                  color: Qt.alpha(root.foreground, 0.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  leftPadding: Style.space(12)
                }
              }
            }
          }

          // ---- show all
          Button {
            width: parent.width
            text: root.showAll ? "Show only findings" : "Show all checks"
            foreground: root.foreground
            accent: root.accent
            bordered: true
            fontSize: Style.font.bodySmall
            enabled: root.ready
            horizontalPadding: Style.spacing.controlPaddingX - Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY - Style.space(1)
            onClicked: root.toggleShowAll()
          }
        }
      }
    }
  }
}

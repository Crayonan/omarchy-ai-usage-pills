import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "bit-dev.ai-usage-pills"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var entries: []
  property string selectedProvider: "anthropic"
  property string loadError: ""
  property string commandStdout: ""
  property string commandStderr: ""
  property bool loading: true
  property bool refreshQueued: false
  property int lastExitCode: 0
  property double nowMs: Date.now()
  property bool settingsOpen: false

  readonly property int refreshIntervalSec: Math.max(30, Math.min(3600,
    Number(setting("refreshIntervalSec", 300)) || 300))
  readonly property var anthropicState: Model.providerState("anthropic", entries, nowMs, loading, loadError)
  readonly property var openaiState: Model.providerState("openai", entries, nowMs, loading, loadError)
  readonly property var antigravityState: Model.providerState("antigravity", entries, nowMs, loading, loadError)
  readonly property var openrouterState: Model.providerState("openrouter", entries, nowMs, loading, loadError)
  readonly property var selectedState: providerState(selectedProvider)
  readonly property var selectedEntry: selectedState ? selectedState.entry : null

  function providerState(id) {
    if (id === "anthropic") return anthropicState
    if (id === "openai") return openaiState
    if (id === "antigravity") return antigravityState
    return openrouterState
  }

  function providerIcon(id) {
    if (id === "anthropic") return Qt.resolvedUrl("../assets/anthropic.svg")
    if (id === "openai") return Qt.resolvedUrl("../assets/openai.svg")
    if (id === "antigravity") return Qt.resolvedUrl("../assets/google-g.svg")
    return Qt.resolvedUrl("../assets/openrouter.svg")
  }

  function openProvider(id, anchor) {
    selectedProvider = Model.PROVIDER_IDS.indexOf(id) >= 0 ? id : "anthropic"
    settingsOpen = false
    if (anchor) anchorItem = anchor
    nowMs = Date.now()
    open()
  }

  function openSettings(anchor) {
    settingsOpen = true
    if (anchor) anchorItem = anchor
    open()
    Qt.callLater(function() { settingsView.forceActiveFocus() })
  }

  function closeSettings() {
    settingsOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function persistWidgetSettings(overrides) {
    var entry = Model.settingsWithOverrides(settings, moduleName, overrides)
    settings = entry
    if (hostWidget && "settings" in hostWidget) hostWidget.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  function applyAppearance(key, value) {
    var patch = ({})
    if (key === "pillOpacity") patch[key] = Model.validOpacity(value)
    else if (key === "anthropicAccent") patch[key] = Model.validColor(value, Model.DEFAULT_ACCENTS.anthropic)
    else if (key === "openaiAccent") patch[key] = Model.validColor(value, Model.DEFAULT_ACCENTS.openai)
    else if (key === "antigravityAccent") patch[key] = Model.validColor(value, Model.DEFAULT_ACCENTS.antigravity)
    else if (key === "openrouterAccent") patch[key] = Model.validColor(value, Model.DEFAULT_ACCENTS.openrouter)
    else return
    persistWidgetSettings(patch)
  }

  function resetAppearance() {
    persistWidgetSettings({
      anthropicAccent: Model.DEFAULT_ACCENTS.anthropic,
      openaiAccent: Model.DEFAULT_ACCENTS.openai,
      antigravityAccent: Model.DEFAULT_ACCENTS.antigravity,
      openrouterAccent: Model.DEFAULT_ACCENTS.openrouter,
      pillOpacity: Model.DEFAULT_OPACITY
    })
  }

  // The bundled native supervisor opens each fixed candidate with O_NOFOLLOW,
  // validates a root-owned, non-writable regular file, then execs that same
  // descriptor. It also owns the process-group deadline and byte caps.
  readonly property string backendLauncher:
    Qt.resolvedUrl("../bin/ai-usage-pills-runner").toString()
  readonly property int processTimeoutSec: 15
  readonly property int maxOutputBytes: 65536
  property bool refreshActive: false
  property bool processStartFailed: false
  property bool processExited: false
  property bool stdoutFinished: false
  property bool stderrFinished: false

  function startRefresh() {
    if (refreshActive || usageProcess.running) {
      refreshQueued = true
      return
    }
    refreshActive = true
    refreshQueued = false
    processStartFailed = false
    processExited = false
    stdoutFinished = false
    stderrFinished = false
    commandStdout = ""
    commandStderr = ""
    if (entries.length === 0) loading = true
    usageProcess.running = true
  }

  function maybeFinishRefresh() {
    if (!refreshActive || !processExited || !stdoutFinished || !stderrFinished) return
    Qt.callLater(function() {
      if (refreshActive && processExited && stdoutFinished && stderrFinished)
        finishRefresh()
    })
  }

  function finishRefresh() {
    var detail = commandStderr.trim()
    if (processStartFailed) {
      loadError = "The bundled ai-usagebar launcher could not be started."
    } else if (lastExitCode === 124) {
      loadError = "ai-usagebar process timed out after " + processTimeoutSec + "s."
    } else if (lastExitCode === 125) {
      loadError = "ai-usagebar produced more than " + Math.round(maxOutputBytes / 1024)
        + " KB on one output stream; the backend was terminated."
    } else if (lastExitCode === 126) {
      loadError = detail
        || "ai-usagebar is unavailable in trusted system paths (/usr/bin, /usr/local/bin)."
    } else if (lastExitCode !== 0) {
      loadError = detail || "ai-usagebar exited unsuccessfully."
    } else {
      var parsed = Model.parseReport(commandStdout)
      if (parsed.ok) {
        entries = parsed.entries
        loadError = ""
      } else {
        loadError = detail || parsed.error
      }
    }
    loading = false
    nowMs = Date.now()
    var runQueued = refreshQueued
    refreshQueued = false
    refreshActive = false
    if (runQueued) Qt.callLater(function() {
      if (!root.refreshActive) root.startRefresh()
    })
  }

  function refresh() { startRefresh() }

  onOpenedChanged: {
    if (opened) {
      nowMs = Date.now()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else settingsOpen = false
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.startRefresh()
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: usageProcess
    running: false
    // The supervisor forwards at most maxOutputBytes per stream. Collecting the
    // bounded bytes to completion lets Qt decode UTF-8 once, so a multibyte
    // character split across pipe reads cannot be corrupted.
    command: [root.backendLauncher, String(root.processTimeoutSec * 1000),
      String(root.maxOutputBytes)]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.commandStdout = String(text || "")
        root.stdoutFinished = true
        root.maybeFinishRefresh()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.commandStderr = String(text || "")
        root.stderrFinished = true
        root.maybeFinishRefresh()
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.processExited = true
      root.lastExitCode = exitCode
      root.maybeFinishRefresh()
    }
    onRunningChanged: {
      // A process that never starts emits no stream or exited signals.
      if (root.refreshActive && !running && !root.processExited) {
        root.processStartFailed = true
        root.processExited = true
        root.stdoutFinished = true
        root.stderrFinished = true
        root.lastExitCode = 2
        root.maybeFinishRefresh()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.settingsOpen
      onActivateRequested: if (!root.settingsOpen) root.refresh()
      onCloseRequested: root.settingsOpen ? root.closeSettings() : root.close()
      onTabRequested: function(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
          root.bar.switchPanelFrom(root.barIdentity, direction)
      }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
        else if (text === "s" || text === "S") root.openSettings(root.anchorItem)
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.settingsOpen ? "AI pill settings" : root.selectedState.title
            meta: root.settingsOpen ? "Colors and tint opacity"
              : (root.selectedEntry && root.selectedEntry.plan ? root.selectedEntry.plan : "Usage report")
            detail: root.settingsOpen ? "Changes are persisted in the bar entry."
              : (root.selectedState.available
                  ? root.selectedState.value + (root.selectedState.reset ? " · resets in " + root.selectedState.reset : "")
                  : root.selectedState.value)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Image {
                source: root.settingsOpen ? Qt.resolvedUrl("../assets/openrouter.svg") : root.providerIcon(root.selectedProvider)
                width: Style.space(30)
                height: width
                fillMode: Image.PreserveAspectFit
                smooth: true
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.space(4)
                PanelActionButton {
                  visible: !root.settingsOpen
                  iconText: "󰑐"
                  tooltipText: "Refresh all four providers"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !root.refreshActive
                  onClicked: root.refresh()
                }
                PanelActionButton {
                  iconText: root.settingsOpen ? "󰁍" : "󰒓"
                  tooltipText: root.settingsOpen ? "Back to usage" : "Appearance settings"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.settingsOpen ? root.closeSettings() : root.openSettings(root.anchorItem)
                }
              }
            }
          }

          SettingsView {
            id: settingsView
            visible: root.settingsOpen
            width: parent.width
            foreground: root.foreground
            urgent: root.urgent
            fontFamily: root.fontFamily
            values: root.settings
            onApplyRequested: function(key, value) { root.applyAppearance(key, value) }
            onResetRequested: root.resetAppearance()
            onCloseRequested: root.closeSettings()
          }

          ListView {
            visible: !root.settingsOpen
            width: parent.width
            height: visible ? Style.spacing.controlHeight : 0
            orientation: ListView.Horizontal
            spacing: Style.space(6)
            clip: true
            model: Model.PROVIDER_IDS

            delegate: Button {
              required property string modelData
              height: ListView.view.height
              text: Model.providerTitle(modelData)
              selected: root.selectedProvider === modelData
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.selectedProvider = modelData
            }
          }

          BorderSurface {
            visible: !root.settingsOpen && (root.selectedState.message !== "" || !root.selectedState.available)
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.space(20)
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.09)
            borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              anchors.fill: parent
              anchors.margins: Style.space(10)
              text: root.selectedState.message
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            id: details
            visible: !root.settingsOpen && root.selectedEntry && root.selectedEntry.sections.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { width: parent.width; foreground: root.foreground }
            PanelSectionHeader {
              text: root.selectedProvider === "openrouter" ? "BALANCE & PERIOD SPEND" : "PROVIDER DETAILS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.selectedEntry ? root.selectedEntry.sections : []

              Column {
                required property var modelData
                width: details.width
                spacing: Style.space(4)

                Item { visible: modelData.type === "spacer"; width: 1; height: Style.space(4) }

                Text {
                  visible: modelData.type === "text" || modelData.type === "metric"
                  width: parent.width
                  text: {
                    var type = String(modelData.type || "")
                    var label = String(modelData.label || "")
                    var value = String(modelData.value || "")
                    if (type === "metric")
                      return label + "    " + (value || String(modelData.percent === undefined ? "" : modelData.percent) + "%")
                    if (type === "text")
                      return value ? label + "    " + value : label.toUpperCase()
                    return ""
                  }
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: modelData.type === "text" && String(modelData.value || "") === "" ? Style.font.caption : Style.font.bodySmall
                  font.bold: modelData.type === "metric" || (modelData.type === "text" && String(modelData.value || "") === "")
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: text !== ""
                  width: parent.width
                  text: {
                    if (modelData.type !== "metric") return ""
                    var parts = []
                    var detail = Model.metricDetail(modelData)
                    if (detail) parts.push(detail)
                    if (modelData.reset_at)
                      parts.push("Resets in " + Model.compactReset(modelData.reset_at, root.nowMs))
                    return parts.join("\n")
                  }
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: modelData.type === "block"
                  width: parent.width
                  text: {
                    if (modelData.type !== "block") return ""
                    var lines = Array.isArray(modelData.body) ? modelData.body : []
                    var label = String(modelData.label || "")
                    return label + (lines.length > 0 ? "\n" + lines.join("\n") : "")
                  }
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          Text {
            visible: !root.settingsOpen && root.selectedState.fetched !== ""
            width: parent.width
            text: Model.formatUpdated(root.selectedState.fetched, root.nowMs)
              + (root.refreshActive ? " · refreshing…" : "")
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }
}

import QtQuick
import QtQuick.Window
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "bit-dev.ai-usage-pills"

  readonly property var panelItem: panelLoader.item
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property real hostWidth: root.Window.window ? root.Window.window.width : 1920
  readonly property string displayMode: vertical ? "minimal"
    : hostWidth < 1100 ? "minimal" : hostWidth < 1600 ? "compact" : "full"
  readonly property real tintOpacity: Model.validOpacity(setting("pillOpacity", Model.DEFAULT_OPACITY))
  readonly property color anthropicAccent: Model.validColor(setting("anthropicAccent", Model.DEFAULT_ACCENTS.anthropic), Model.DEFAULT_ACCENTS.anthropic)
  readonly property color openaiAccent: Model.validColor(setting("openaiAccent", Model.DEFAULT_ACCENTS.openai), Model.DEFAULT_ACCENTS.openai)
  readonly property color antigravityAccent: Model.validColor(setting("antigravityAccent", Model.DEFAULT_ACCENTS.antigravity), Model.DEFAULT_ACCENTS.antigravity)
  readonly property color openrouterAccent: Model.validColor(setting("openrouterAccent", Model.DEFAULT_ACCENTS.openrouter), Model.DEFAULT_ACCENTS.openrouter)

  function injectPanel() {
    if (!panelItem) return
    panelItem.bar = root.bar
    panelItem.settings = root.settings
    panelItem.hostWidget = root
  }

  function open() {
    if (panelItem) panelItem.openProvider(panelItem.selectedProvider || "anthropic", anthropicPill)
  }
  function close() { if (panelItem) panelItem.close() }
  function toggle() {
    if (!panelItem) return
    if (panelItem.opened) panelItem.close()
    else open()
  }
  function closeForPopoutSwitch() { if (panelItem) panelItem.closeForPopoutSwitch() }
  function refresh() { if (panelItem) panelItem.refresh() }

  function handlePress(providerId, anchor, buttonCode) {
    if (!panelItem) return
    if (buttonCode === Qt.MiddleButton) panelItem.refresh()
    else if (buttonCode === Qt.RightButton) panelItem.openSettings(anchor)
    else panelItem.openProvider(providerId, anchor)
  }

  implicitWidth: pillRow.implicitWidth
  implicitHeight: vertical ? pillColumn.implicitHeight : (bar ? bar.barSize : Style.bar.sizeHorizontal)

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

  Row {
    id: pillRow
    visible: !root.vertical
    spacing: Style.space(3)

    UsagePill {
      id: anthropicPill
      bar: root.bar
      state: root.panelItem ? root.panelItem.anthropicState : null
      iconSource: Qt.resolvedUrl("../assets/anthropic.svg")
      accent: root.anthropicAccent
      tintOpacity: root.tintOpacity
      displayMode: root.displayMode
      onPressed: function(buttonCode) { root.handlePress("anthropic", anthropicPill, buttonCode) }
    }
    UsagePill {
      id: openaiPill
      bar: root.bar
      state: root.panelItem ? root.panelItem.openaiState : null
      iconSource: Qt.resolvedUrl("../assets/openai.svg")
      accent: root.openaiAccent
      tintOpacity: root.tintOpacity
      displayMode: root.displayMode
      onPressed: function(buttonCode) { root.handlePress("openai", openaiPill, buttonCode) }
    }
    UsagePill {
      id: antigravityPill
      bar: root.bar
      state: root.panelItem ? root.panelItem.antigravityState : null
      iconSource: Qt.resolvedUrl("../assets/google-g.svg")
      accent: root.antigravityAccent
      tintOpacity: root.tintOpacity
      displayMode: root.displayMode
      googleMark: true
      onPressed: function(buttonCode) { root.handlePress("antigravity", antigravityPill, buttonCode) }
    }
    UsagePill {
      id: openrouterPill
      bar: root.bar
      state: root.panelItem ? root.panelItem.openrouterState : null
      iconSource: Qt.resolvedUrl("../assets/openrouter.svg")
      accent: root.openrouterAccent
      tintOpacity: root.tintOpacity
      displayMode: root.displayMode
      onPressed: function(buttonCode) { root.handlePress("openrouter", openrouterPill, buttonCode) }
    }
  }

  Column {
    id: pillColumn
    visible: root.vertical
    spacing: Style.space(3)

    Repeater {
      model: [
        { id: "anthropic", icon: "../assets/anthropic.svg", accent: root.anthropicAccent },
        { id: "openai", icon: "../assets/openai.svg", accent: root.openaiAccent },
        { id: "antigravity", icon: "../assets/google-g.svg", accent: root.antigravityAccent },
        { id: "openrouter", icon: "../assets/openrouter.svg", accent: root.openrouterAccent }
      ]
      UsagePill {
        required property var modelData
        width: root.barSize
        bar: root.bar
        state: root.panelItem ? root.panelItem.providerState(modelData.id) : null
        iconSource: Qt.resolvedUrl(modelData.icon)
        accent: modelData.accent
        tintOpacity: root.tintOpacity
        displayMode: "minimal"
        onPressed: function(buttonCode) { root.handlePress(modelData.id, root, buttonCode) }
      }
    }
  }
}

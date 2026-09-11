import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var bar: null
  property var state: null
  property url iconSource
  property color accent: "#6566F1"
  property real tintOpacity: 0.24
  property string displayMode: "full" // full | compact | minimal
  property bool googleMark: false
  property var registeredBar: null

  signal pressed(int button)

  readonly property bool available: state && state.available === true
  readonly property bool stale: state && state.stale === true
  readonly property string tooltipText: modelSafe.tooltip(state)
  readonly property bool tooltipHovered: visible && mouseArea.containsMouse
  readonly property bool interactive: true
  readonly property bool pressable: true
  readonly property bool concealed: false
  readonly property color baseColor: bar ? bar.background : Color.background
  readonly property color compositeColor: Qt.rgba(
    accent.r * tintOpacity + baseColor.r * (1 - tintOpacity),
    accent.g * tintOpacity + baseColor.g * (1 - tintOpacity),
    accent.b * tintOpacity + baseColor.b * (1 - tintOpacity), 1)
  readonly property color textColor: contrastColor(compositeColor)

  function linearChannel(channel) {
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function contrastColor(color) {
    var luminance = 0.2126 * linearChannel(color.r)
      + 0.7152 * linearChannel(color.g) + 0.0722 * linearChannel(color.b)
    var whiteRatio = 1.05 / (luminance + 0.05)
    var blackRatio = (luminance + 0.05) / 0.05
    return whiteRatio >= blackRatio ? "#FFFFFF" : "#000000"
  }

  function triggerPress(button) {
    if (bar) bar.hideTooltip(root)
    pressed(button)
  }

  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    registeredBar = bar
    if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(root)
  }

  onBarChanged: syncClickRegistration()
  Component.onCompleted: syncClickRegistration()
  Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)

  implicitWidth: pillRow.implicitWidth + Style.space(displayMode === "minimal" ? 8 : 12)
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    height: Math.max(Style.space(20), parent.height - Style.space(5))
    radius: height / 2
    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, root.tintOpacity)
    border.width: root.stale || !root.available ? 1 : 0
    border.color: root.stale ? (root.bar ? root.bar.urgent : Color.urgent) : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.34)
  }

  Row {
    id: pillRow
    anchors.centerIn: parent
    spacing: Style.space(4)

    Image {
      width: Style.space(14)
      height: width
      anchors.verticalCenter: parent.verticalCenter
      source: root.iconSource
      fillMode: Image.PreserveAspectFit
      smooth: true
      mipmap: true
    }

    Text {
      visible: root.displayMode !== "minimal"
      anchors.verticalCenter: parent.verticalCenter
      text: root.state ? root.state.value : "…"
      textFormat: Text.PlainText
      color: root.textColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Rectangle {
      visible: root.displayMode === "full" && root.state && root.state.reset !== ""
      anchors.verticalCenter: parent.verticalCenter
      width: 1
      height: Style.space(10)
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.32)
    }

    Text {
      visible: root.displayMode === "full" && root.state && root.state.reset !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.state ? root.state.reset : ""
      textFormat: Text.PlainText
      color: root.textColor
      opacity: 0.82
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      visible: root.stale || !root.available
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(4)
      height: width
      radius: width / 2
      color: root.bar ? root.bar.urgent : Color.urgent
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltipText)
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onClicked: function(mouse) { root.triggerPress(mouse.button) }
  }

  // Tiny local namespace avoids importing the model from every delegate user.
  QtObject {
    id: modelSafe
    function tooltip(state) {
      if (!state) return "AI usage"
      var parts = [state.title, state.value]
      if (state.reset) parts.push("resets in " + state.reset)
      if (state.stale) parts.push("stale")
      if (state.message) parts.push(state.message)
      return parts.join(" · ")
    }
  }
}

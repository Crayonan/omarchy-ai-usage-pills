import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

Column {
  id: root

  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property var values: ({})

  signal applyRequested(string key, var value)
  signal resetRequested()
  signal closeRequested()

  spacing: Style.space(12)
  focus: visible
  Keys.onEscapePressed: closeRequested()

  function configured(key, fallback) {
    return Model.validColor(values && values[key], fallback)
  }


  PanelSectionHeader {
    text: "PILL APPEARANCE"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Text {
    width: parent.width
    text: "Enter #RRGGBB colors. Invalid values fall back to that provider’s default. Swatches preview valid edits; saved changes apply to every monitor."
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.45)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Repeater {
    model: [
      { label: "Anthropic", key: "anthropicAccent", fallback: Model.DEFAULT_ACCENTS.anthropic, field: "anthropic" },
      { label: "OpenAI", key: "openaiAccent", fallback: Model.DEFAULT_ACCENTS.openai, field: "openai" },
      { label: "Google", key: "antigravityAccent", fallback: Model.DEFAULT_ACCENTS.antigravity, field: "google" },
      { label: "OpenRouter", key: "openrouterAccent", fallback: Model.DEFAULT_ACCENTS.openrouter, field: "openrouter" }
    ]

    Item {
      required property var modelData
      width: parent.width
      implicitHeight: colorRow.implicitHeight

      Row {
        id: colorRow
        width: parent.width
        spacing: Style.space(8)

        Rectangle {
          width: Style.space(26)
          height: colorInput.implicitHeight
          radius: Style.cornerRadius
          color: Model.validColor(colorInput.text, modelData.fallback)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
        }

        Column {
          width: parent.width - Style.space(26) - parent.spacing
          spacing: Style.space(4)

          Text {
            text: modelData.label
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          TextField {
            id: colorInput
            width: parent.width
            text: root.configured(modelData.key, modelData.fallback)
            placeholderText: modelData.fallback
            foreground: root.foreground
            validator: RegularExpressionValidator { regularExpression: /^#[0-9a-fA-F]{6}$/ }
            onEditingFinished: {
              var next = Model.validColor(text, modelData.fallback)
              text = next
              root.applyRequested(modelData.key, next)
            }
            Keys.onEscapePressed: root.closeRequested()
          }
        }
      }
    }
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  NumberField {
    width: parent.width
    label: "Tint opacity (%)"
    value: Math.round(Model.validOpacity(root.values && root.values.pillOpacity) * 100)
    from: 8
    to: 85
    stepSize: 1
    foreground: root.foreground
    fontFamily: root.fontFamily
    onModified: function(next) { root.applyRequested("pillOpacity", next / 100) }
  }

  Text {
    width: parent.width
    text: "The Google G keeps its official multicolor artwork; its accent controls the surrounding tint only. Backend credentials remain owned by ai-usagebar and are never loaded here."
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.45)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Row {
    width: parent.width
    spacing: Style.space(8)

    Button {
      width: (parent.width - parent.spacing) / 2
      text: "Reset defaults"
      iconText: "󰑐"
      bordered: true
      focusable: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.resetRequested()
    }

    Button {
      width: (parent.width - parent.spacing) / 2
      text: "Done"
      iconText: "󰄬"
      bordered: true
      focusable: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.closeRequested()
    }
  }
}

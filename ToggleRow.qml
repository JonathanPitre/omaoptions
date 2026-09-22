import QtQuick
import qs.Ui
import qs.Commons

// Compact "label on the left, switch on the right" row.
Item {
  id: row

  property QtObject bar: null
  property string label: ""
  property string description: ""
  property bool checked: false

  signal toggled()

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string ff: bar ? bar.fontFamily : Style.font.family

  width: parent ? parent.width : 0
  implicitHeight: Math.max(sw.implicitHeight, labels.implicitHeight)

  Column {
    id: labels
    anchors.left: parent.left
    anchors.right: sw.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      width: parent.width
      text: row.label
      color: row.fg
      font.family: row.ff
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
    Text {
      visible: row.description !== ""
      width: parent.width
      text: row.description
      color: row.fg
      opacity: 0.6
      font.family: row.ff
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }
  }

  ToggleSwitch {
    id: sw
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    checked: row.checked
    foreground: row.fg
    onToggled: row.toggled()
  }

  MouseArea {
    anchors.fill: labels
    cursorShape: Qt.PointingHandCursor
    onClicked: row.toggled()
  }
}

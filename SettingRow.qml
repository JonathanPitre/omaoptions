import QtQuick
import qs.Ui
import qs.Commons

// Compact "label on the left, dropdown on the right" row. Dropdowns don't
// react to the scroll wheel, so scrolling the panel can't change a value.
Item {
  id: row

  property QtObject bar: null
  property string label: ""
  property string description: ""
  property string value: ""
  property var options: []
  property real controlWidth: Style.space(200)

  signal changed(string value)

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string ff: bar ? bar.fontFamily : Style.font.family

  width: parent ? parent.width : 0
  implicitHeight: Math.max(dropdown.implicitHeight, labels.implicitHeight)

  Column {
    id: labels
    anchors.left: parent.left
    anchors.right: dropdown.left
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

  Dropdown {
    id: dropdown
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: row.controlWidth
    showLabel: false
    value: row.value
    options: row.options
    foreground: row.fg
    fontFamily: row.ff
    onChanged: function(v) { row.changed(v) }
  }
}

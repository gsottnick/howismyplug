import QtQuick
import qs.Commons

// A one-shot burst of stars flying out from the center, for items that got
// paid off since the popup was last opened.
Item {
  id: root
  property color color: Color.accent
  property int count: 10
  property real reach: 34

  function burst() {
    for (var i = 0; i < stars.count; i++) stars.itemAt(i).fly()
  }

  Repeater {
    id: stars
    model: root.count
    Text {
      id: star
      readonly property real angle: (index / root.count) * 2 * Math.PI + (index % 2) * 0.3
      property real t: 0
      text: index % 3 === 0 ? "✦" : (index % 3 === 1 ? "✧" : "·")
      color: index % 2 ? root.color : Qt.hsva((index / root.count), 0.7, 1, 1)
      font.pixelSize: 10 + (index % 3) * 3
      x: root.width / 2 - width / 2 + Math.cos(angle) * root.reach * t
      y: root.height / 2 - height / 2 + Math.sin(angle) * root.reach * t
      opacity: t > 0 ? 1 - t : 0
      scale: 0.6 + t
      function fly() { a.restart() }
      NumberAnimation {
        id: a
        target: star; property: "t"
        from: 0; to: 1
        duration: 900 + (index % 4) * 150
        easing.type: Easing.OutQuad
      }
    }
  }
}

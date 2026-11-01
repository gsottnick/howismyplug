import QtQuick
import qs.Commons

// Matrix-style rain of token glyphs behind the popup. Only animates while
// `running` (the popup is open), so it costs nothing when closed.
Canvas {
  id: root

  property bool running: false
  property color glyphColor: Color.accent
  property int cell: 14
  property string glyphs: "0123456789abcdef$¢∑⟨⟩{}<>/*+-=#"

  property var drops: []

  function reset() {
    var cols = Math.max(1, Math.floor(width / cell))
    var d = []
    for (var i = 0; i < cols; i++)
      d.push({ y: -Math.random() * height, speed: 0.6 + Math.random() * 1.6, len: 4 + Math.floor(Math.random() * 10) })
    drops = d
  }

  onWidthChanged: reset()
  onHeightChanged: reset()
  onRunningChanged: if (running) reset()

  Timer {
    interval: 50
    repeat: true
    running: root.running && root.visible
    onTriggered: root.requestPaint()
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    if (!root.running) return
    ctx.font = (cell - 2) + "px monospace"
    var c = root.glyphColor
    for (var i = 0; i < drops.length; i++) {
      var dr = drops[i]
      dr.y += dr.speed * cell * 0.35
      if (dr.y - dr.len * cell > height) {
        dr.y = -Math.random() * height * 0.5
        dr.speed = 0.6 + Math.random() * 1.6
      }
      for (var k = 0; k < dr.len; k++) {
        var y = dr.y - k * cell
        if (y < -cell || y > height + cell) continue
        var a = k === 0 ? 0.9 : (1 - k / dr.len) * 0.45
        ctx.fillStyle = Qt.rgba(c.r, c.g, c.b, a)
        ctx.fillText(glyphs.charAt(Math.floor(Math.random() * glyphs.length)), i * cell + 2, y)
      }
    }
  }
}

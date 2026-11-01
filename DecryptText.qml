import QtQuick
import qs.Commons

// TTE "decrypt"-style text: random glyphs settle into the real text from
// left to right. Plays whenever `target` changes or play() is called.
Text {
  id: root

  property string target: ""
  property color scrambleColor: Color.accent
  property color settledColor: Color.foreground
  property int duration: 900
  property string glyphs: "0123456789ABCDEF$#%&*+=<>?@~▓▒░"

  property real _p: 1                      // 0..1 progress
  textFormat: Text.StyledText
  text: _render(_p, _seed)
  property int _seed: 0

  function play() {
    anim.stop()
    _p = 0
    anim.start()
  }

  onTargetChanged: play()

  function _esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  function _render(p, seed) {
    var t = root.target
    if (p >= 1) return "<font color='" + root.settledColor + "'>" + _esc(t) + "</font>"
    var n = t.length
    var settled = Math.floor(p * (n + 4)) - 4          // a scrambled band runs ahead
    var a = "", b = ""
    for (var i = 0; i < n; i++) {
      var ch = t.charAt(i)
      if (i < settled) a += ch
      else if (ch === " ") b += " "
      else b += root.glyphs.charAt(Math.floor(Math.random() * root.glyphs.length))
    }
    return "<font color='" + root.settledColor + "'>" + _esc(a) + "</font>"
         + "<font color='" + root.scrambleColor + "'>" + _esc(b) + "</font>"
  }

  NumberAnimation {
    id: anim
    target: root
    property: "_p"
    from: 0; to: 1
    duration: root.duration
    easing.type: Easing.InOutQuad
  }

  // re-roll scramble glyphs ~30 fps while animating
  Timer {
    interval: 33
    repeat: true
    running: anim.running
    onTriggered: root._seed++
  }
}

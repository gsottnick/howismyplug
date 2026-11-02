import QtQuick
import qs.Commons

// Milestone confetti burst: ~110 pieces drop from above with gravity,
// horizontal flutter, rotation, and alpha fade. Fully stops when done.
// Inspired by TokenRain.qml animation idiom.
Canvas {
  id: root
  anchors.fill: parent
  antialiasing: true

  property color glyphColor: Color.accent
  property color fgColor: Color.foreground

  property var particles: []
  property bool running: false
  property real startTime: 0

  readonly property int count: 110
  readonly property real maxLife: 3200
  readonly property real burstDuration: 2800

  function burst() {
    root.particles = []
    spawnParticles()
    root.running = true
    root.startTime = Date.now()
    root.requestPaint()
  }

  function reset() {
    root.particles = []
    root.running = false
    root.requestPaint()
  }

  function isDone() {
    return root.running && (Date.now() - root.startTime) > root.burstDuration + 500
  }

  Timer {
    interval: 50
    repeat: true
    running: root.running && root.visible
    onTriggered: {
      if (root.isDone()) {
        root.running = false
        root.reset()
      } else {
        root.requestPaint()
      }
    }
  }

  function spawnParticles() {
    var w = root.width || 400
    var n = root.count
    for (var i = 0; i < n; i++) {
      var size = 3 + Math.floor(Math.random() * 5) // 3-7 px
      var slim = Math.random() < 0.25 ? 2 : size    // ~25% are 2px slims
      var hueComp = Math.random() < 0.15             // ~15% complementary hue
      var alphaBase = 0.6 + Math.random() * 0.4
      // Stagger: spread births over <=400ms window
      var birth = (i / (n - 1)) * 400 + Math.random() * 50
      root.particles.push({
        x: Math.random() * w,
        y: -10 - Math.random() * 40,
        vx: (Math.random() - 0.5) * 1.5,
        vy: 1.5 + Math.random() * 2.5,
        grav: 0.04 + Math.random() * 0.06,
        flutterAmp: 0.3 + Math.random() * 1.2,
        flutterFreq: 0.003 + Math.random() * 0.006,
        phase: Math.random() * Math.PI * 2,
        rot: Math.random() * 360,
        rotSpeed: (Math.random() - 0.5) * 8,
        w: slim,
        h: size,
        life: 2500 + Math.random() * 700,
        birth: birth,
        hueComp: hueComp,
        alphaBase: alphaBase,
        isFg: Math.random() < 0.3  // pre-compute fg vs accent
      })
    }
  }

  onPaint: {
    var ctx = root.getContext("2d")
    ctx.reset()
    if (!root.running && root.particles.length === 0) return

    var elapsed = Date.now() - root.startTime
    var w = root.width || 400
    var h = root.height || 300
    var accent = root.glyphColor
    var fg = root.fgColor

    for (var i = 0; i < root.particles.length; i++) {
      var p = root.particles[i]
      var age = elapsed - p.birth
      if (age < 0 || age > p.life) continue

      // Update position
      p.vy += p.grav
      p.y += p.vy
      p.x += p.vx + Math.sin(age * p.flutterFreq + p.phase) * p.flutterAmp
      p.rot += p.rotSpeed

      // Cull offscreen
      if (p.y > h + 20 || p.x < -20 || p.x > w + 20) continue

      // Alpha fade over final ~25% of life
      var lifeRatio = age / p.life
      var alpha = p.alphaBase
      if (lifeRatio > 0.75) {
        alpha *= 1 - (lifeRatio - 0.75) / 0.25
      }
      if (alpha <= 0) continue

      // Color selection (pre-computed, no random in paint loop)
      var col
      if (p.hueComp) {
        // Complementary hue from accent (shift by 0.5 in hue space)
        col = Qt.hsla((Math.max(accent.hslHue, 0) + 0.5) % 1.0, Math.max(accent.hslSaturation, 0.5), 0.6, alpha)
      } else if (p.isFg) {
        // White/fg pieces
        col = Qt.rgba(fg.r, fg.g, fg.b, alpha * 0.8)
      } else {
        // Accent color with varied alpha
        col = Qt.rgba(accent.r, accent.g, accent.b, alpha)
      }

      ctx.save()
      ctx.translate(p.x + p.w / 2, p.y + p.h / 2)
      ctx.rotate(p.rot * Math.PI / 180)
      ctx.fillStyle = col
      ctx.fillRect(-p.w / 2, -p.h / 2, p.w, p.h)
      ctx.restore()
    }
  }
}

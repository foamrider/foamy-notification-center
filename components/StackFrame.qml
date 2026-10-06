import QtQuick
import qs.Commons

// Separate list rows share one card outline while remaining independently virtualized.
Canvas {
  id: root
  property bool first: false
  property bool last: false
  property bool critical: false
  property color fill: Color.popups.background
  property color foreground: Color.foreground
  readonly property color outline: Util.alpha(foreground, 0.18)
  readonly property color urgent: Color.urgent
  readonly property real corner: Math.min(Style.cornerRadius * 2, width / 2, height / 2)
  readonly property real leading: critical ? Style.space(3) : 1

  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  onFirstChanged: requestPaint()
  onLastChanged: requestPaint()
  onCriticalChanged: requestPaint()
  onFillChanged: requestPaint()
  onOutlineChanged: requestPaint()
  onUrgentChanged: requestPaint()
  onCornerChanged: requestPaint()

  onPaint: {
    var c = getContext("2d")
    c.reset()
    function shape(x, y, w, h, tl, tr, br, bl) {
      c.beginPath()
      c.moveTo(x + tl, y)
      c.lineTo(x + w - tr, y)
      c.arcTo(x + w, y, x + w, y + tr, tr)
      c.lineTo(x + w, y + h - br)
      c.arcTo(x + w, y + h, x + w - br, y + h, br)
      c.lineTo(x + bl, y + h)
      c.arcTo(x, y + h, x, y + h - bl, bl)
      c.lineTo(x, y + tl)
      c.arcTo(x, y, x + tl, y, tl)
      c.closePath()
    }
    var top = root.first ? root.corner : 0
    var bottom = root.last ? root.corner : 0
    shape(0, 0, width, height, top, top, bottom, bottom)
    c.fillStyle = root.outline
    c.fill()
    var y = root.first ? 1 : 0
    var h = height - y - (root.last ? 1 : 0)
    shape(1, y, width - 2, h,
          Math.max(0, top - 1), Math.max(0, top - 1),
          Math.max(0, bottom - 1), Math.max(0, bottom - 1))
    c.fillStyle = root.fill
    c.fill()
    if (root.critical) {
      // Only the first and last virtualized rows curve; intermediate edges join flush.
      c.fillStyle = root.urgent
      c.beginPath()
      c.moveTo(top, 0)
      if (top) c.arc(top, top, top, -Math.PI / 2, -Math.PI, true)
      c.lineTo(0, height - bottom)
      if (bottom) c.arc(bottom, height - bottom, bottom, Math.PI, Math.PI / 2, true)
      else c.lineTo(root.leading, height)
      if (bottom) {
        for (var i = 0; i <= 24; i++) {
          var angle = Math.PI / 2 + i * Math.PI / 48
          var inner = bottom + root.leading * Math.cos(angle)
          c.lineTo(bottom + inner * Math.cos(angle), height - bottom + inner * Math.sin(angle))
        }
      }
      c.lineTo(root.leading, top)
      if (top) {
        for (var j = 0; j <= 24; j++) {
          var topAngle = -Math.PI + j * Math.PI / 48
          var topInner = top + root.leading * Math.cos(topAngle)
          c.lineTo(top + topInner * Math.cos(topAngle), top + topInner * Math.sin(topAngle))
        }
      }
      c.closePath()
      c.fill()
    }
  }
}

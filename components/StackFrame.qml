import QtQuick
import qs.Commons
import qs.Commons as Commons
import "../kit"

// Separate list rows share one card outline while remaining independently virtualized.
Canvas {
  id: root
  transform: Scale {
    origin.x: root.width / 2
    xScale: FoamyI18n.rightToLeft ? -1 : 1
  }
  property bool first: false
  property bool last: false
  property bool critical: false
  property color foreground: Commons.Color.foreground
  // The fills of a stack's frames: its header, a critical row, another row
  // (FoamyPalette.background is the popup's Commons.Color.popups.background),
  // and a row's action buttons, which lie against the edge.
  readonly property color headerFill: Qt.tint(FoamyPalette.background, Util.alpha(foreground, 0.055))
  readonly property color criticalFill: Qt.tint(FoamyPalette.background, Util.alpha(Commons.Color.urgent, 0.09))
  readonly property color rowFill: FoamyPalette.background
  readonly property color actionFill: headerFill
  readonly property color actionHoverFill: Qt.tint(FoamyPalette.background, Util.alpha(foreground, 0.10))
  property color fill: rowFill
  function actionFillFor(hovered) {
    return hovered ? actionHoverFill : actionFill
  }
  readonly property color outline: Util.alpha(foreground, 0.18)
  // The critical edge runs down a whole stack, one frame per row: one
  // colour for all of it, readable on the strictest fill it crosses.
  readonly property color urgent: {
    if (!critical)
      return Commons.Color.urgent
    var fills = [headerFill, criticalFill, rowFill, actionFill, actionHoverFill]
    var strictest = fills.reduce(function (a, b) {
      return FoamyPalette.contrastRatio(Commons.Color.urgent, a) <= FoamyPalette.contrastRatio(Commons.Color.urgent, b) ? a : b
    })
    return FoamyPalette.onSurface(Commons.Color.urgent, strictest)
  }
  readonly property real corner: Math.min(FoamyStyle.radius, width / 2, height / 2)
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
    shape(1, y, width - 2, h, Math.max(0, top - 1), Math.max(0, top - 1), Math.max(0, bottom - 1), Math.max(0, bottom - 1))
    c.fillStyle = root.fill
    c.fill()
    if (root.critical) {
      // Only the first and last virtualized rows curve; intermediate edges join flush.
      c.fillStyle = root.urgent
      c.beginPath()
      c.moveTo(top, 0)
      if (top)
        c.arc(top, top, top, -Math.PI / 2, -Math.PI, true)
      c.lineTo(0, height - bottom)
      if (bottom)
        c.arc(bottom, height - bottom, bottom, Math.PI, Math.PI / 2, true)
      else
        c.lineTo(root.leading, height)
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

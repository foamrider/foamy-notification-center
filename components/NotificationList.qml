import QtQuick
import QtQuick.Controls

ListView {
  id: root
  property var rows: []
  property var rowsById: ({})
  property real entranceDistance: 8
  // Detaching the model releases delegates even while the popup is unmapped.
  property bool contentActive: true
  // Rebuilding offscreen should not start entrance animations before mapping.
  property bool animateChanges: true
  model: contentActive ? rowModel : null
  ListModel { id: rowModel }
  onRowsChanged: reconcileRows()
  Component.onCompleted: reconcileRows()

  function reconcileRows() {
    var next = Object.create(null)
    for (var i = 0; i < rows.length; i++) next[rows[i].id] = rows[i]
    // Remove while departing delegates can still snapshot their old data.
    for (var j = rowModel.count - 1; j >= 0; j--)
      if (!next[rowModel.get(j).rowId]) rowModel.remove(j)
    // Keep shared group objects out of ListModel: copying every expanded group's
    // entries into each row would turn a large stack into quadratic storage.
    rowsById = next
    for (var target = 0; target < rows.length; target++) {
      var id = rows[target].id, found = -1
      for (var k = target; k < rowModel.count; k++) {
        if (rowModel.get(k).rowId === id) { found = k; break }
      }
      if (found < 0) rowModel.insert(target, {rowId: id})
      else if (found !== target) rowModel.move(found, target, 1)
    }
  }

  add: Transition {
    enabled: root.model === rowModel && root.animateChanges
    ParallelAnimation {
      NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 180; easing.type: Easing.OutCubic }
      NumberAnimation { property: "entranceOffset"; from: root.entranceDistance; to: 0; duration: 180; easing.type: Easing.OutCubic }
    }
  }
  populate: add
  // Removal already closes space by animating delegate height. A second y
  // transition can leave Qt's visible range and content-size estimate stale.
  moveDisplaced: Transition {
    enabled: root.model === rowModel && root.animateChanges
    NumberAnimation { property: "y"; duration: 140; easing.type: Easing.OutCubic }
  }

  property real wheelStep: 96
  property real scrollbarWidth: 6
  property real scrollbarInset: 2

  clip: true
  boundsBehavior: Flickable.StopAtBounds
  flickableDirection: Flickable.VerticalFlick
  interactive: contentHeight > height

  function scrollBy(delta, smooth) {
    if (!delta || !interactive) return
    // Accumulate fast wheel ticks against their destination, not an unfinished frame.
    var start = wheelMotion.running ? wheelMotion.to : contentY
    wheelMotion.stop()
    var end = Math.max(originY, Math.min(originY + Math.max(0, contentHeight - height), start + delta))
    if (smooth) {
      wheelMotion.from = contentY
      wheelMotion.to = end
      wheelMotion.start()
    } else contentY = end
  }

  onDraggingChanged: if (dragging) wheelMotion.stop()

  NumberAnimation {
    id: wheelMotion
    target: root
    property: "contentY"
    duration: 120
    easing.type: Easing.OutCubic
  }

  WheelHandler {
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: function(event) {
      var pixels = event.pixelDelta.y
      var angle = event.angleDelta.y
      if (!pixels && !angle) return
      root.scrollBy(pixels ? -pixels : -angle / 120 * root.wheelStep, !pixels)
      event.accepted = true
    }
  }

  ScrollBar.vertical: ScrollBar {
    width: root.scrollbarWidth
    padding: 0
    active: root.interactive
    anchors.right: parent.right
    anchors.rightMargin: root.scrollbarInset
    policy: ScrollBar.AsNeeded
    onPressedChanged: if (pressed) wheelMotion.stop()
  }
}

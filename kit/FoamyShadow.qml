pragma ComponentBehavior: Bound
// foamy-kit 0.17.0 b09817c8b83b3e300ae23f9e7136c896c1363e0452b924cfc9f697cff4bbd17b — do not edit; change foamy-kit and run sync
import QtQuick

// A soft drop shadow under a surface that floats over the card (a raised
// menu, a list that hangs from a field), drawn without effects: MultiEffect
// draws nothing under the software renderer. Stacked rounded rectangles,
// each a step larger and faint; where they overlap they add up, so the
// shadow is darkest at the surface's edge and fades outward. It reaches
// `spread` past the surface's sides and bottom and drops by `offsetY`.
// Put it before the surface (under it), with the surface's geometry:
//
//   FoamyShadow { x: list.x; y: list.y; width: list.width; height: list.height; radius: list.radius; visible: list.visible }
//   Rectangle { id: list; radius: FoamyStyle.radius; color: FoamyPalette.raisedMenuFill; … }
//
// Static: nothing animates. It takes no pointer input.
Item {
  id: shadow
  property real radius: FoamyStyle.radius
  property real spread: FoamyStyle.gapLarge
  property real offsetY: FoamyStyle.gapSmall
  // The darkest the stack gets (where every layer overlaps): softer in a
  // light theme, where a dark shadow reads as a smudge.
  property real strength: FoamyPalette.lightTheme ? 0.16 : 0.42
  readonly property int layers: 5
  Repeater {
    model: shadow.layers
    Rectangle {
      required property int index
      readonly property real grow: (index + 1) * shadow.spread / shadow.layers
      x: -grow
      y: -grow + shadow.offsetY
      width: shadow.width + grow * 2
      height: shadow.height + grow * 2
      radius: shadow.radius + grow
      color: Qt.rgba(0, 0, 0, shadow.strength / shadow.layers)
    }
  }
}

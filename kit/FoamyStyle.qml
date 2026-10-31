pragma Singleton
// foamy-kit 0.4.0 4ef879065729b119638b636e2d145f76eeb24c59533c2d036892b1540d865a53 — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons
import qs.Commons as Commons

// Foamy design tokens: the one place the foamy look is defined, so every
// foamy plugin matches every other one. Values follow DESIGN.md. Sizes go
// through Style.space() so they follow the theme's [spacing] scale.
//
//   FoamyStyle.radius             surfaces, rows, inputs, buttons (2x Hyprland rounding)
//   FoamyStyle.font.body          named type scale (caption … displayLarge)
//   FoamyStyle.popupWidth         420 standard, popupWidthWide 560 for data-dense panels
//   FoamyStyle.popupBorderSpec    1px alpha(popups.text, 0.15)
QtObject {
  id: root

  // --- shape -----------------------------------------------------------------
  // The foamy signature: twice Hyprland's decoration:rounding (0 stays square).
  readonly property real radius: Style.cornerRadius * 2
  // Nested surfaces (a row inside a card, a chip inside a row).
  readonly property real radiusSmall: Style.cornerRadius
  readonly property bool rounded: radius > 0
  // A pill only when the theme rounds corners at all.
  function pillRadius(height) { return rounded ? height / 2 : 0 }
  // Radius for a surface inset by `inset` inside one with radius `outer`.
  function innerRadius(outer, inset) { return Math.max(0, outer - inset) }

  // --- surfaces --------------------------------------------------------------
  readonly property int borderWidth: 1
  readonly property var popupBorderSpec: Border.flat(FoamyPalette.border, borderWidth)
  readonly property real disabledOpacity: 0.45

  // --- type ------------------------------------------------------------------
  // Body text is the foamy sans; numbers, code and glyph fonts use monoFamily
  // (the Omarchy font, which follows `omarchy font set`).
  readonly property string fontFamily: "sans-serif"
  readonly property string monoFamily: Style.font.family
  readonly property QtObject font: QtObject {
    readonly property int caption: Style.space(10)
    readonly property int bodySmall: Style.space(11)
    readonly property int body: Style.space(12)
    readonly property int subtitle: Style.space(13)
    readonly property int title: Style.space(14)
    readonly property int heading: Style.space(16)
    readonly property int iconLarge: Style.space(18)
    readonly property int display: Style.space(24)
    readonly property int displayLarge: Style.space(28)
    // Hero numerals: the one big number a panel is about (clock face,
    // temperature, volume, countdown). numeralCompact for a second hero
    // number or short screens. Units beside a numeral use `display`.
    // Pair with monoFamily or font.features for steady digits.
    readonly property int numeral: Style.space(56)
    readonly property int numeralCompact: Style.space(40)
  }

  // --- popup geometry ----------------------------------------------------------
  readonly property int popupWidth: Style.space(420)
  readonly property int popupWidthWide: Style.space(560)
  // A height cap a panel may opt into (FoamyPopup.maxHeight). By default
  // popups grow to the screen's available height instead (kit 0.4.0).
  readonly property int popupMaxHeight: Style.space(640)
  readonly property int menuWidth: Style.space(232)
  // Hero band (FoamyHeroBand): compact paddings around the title row and hero.
  readonly property int bandPaddingTop: Style.space(16)
  readonly property int bandPaddingBottom: Style.space(16)
  readonly property int bandGap: Style.space(14)
  // Band corners meet the inside of the 1px popup border.
  readonly property real bandRadius: innerRadius(radius, borderWidth)
  // Inner padding of FoamyPopupCard menus (the stock tray menu uses 8 too).
  readonly property int menuPadding: Style.space(8)
  // Inner padding of popup content (the card itself has padding 0 so lists
  // can scroll edge to edge).
  readonly property int padding: Style.space(20)

  // --- spacing -----------------------------------------------------------------
  readonly property int gapTiny: Style.space(2)
  readonly property int gapSmall: Style.space(4)
  readonly property int gap: Style.space(8)
  readonly property int gapLarge: Style.space(12)
  readonly property int sectionGap: Style.space(14)
  readonly property int rowPadding: Style.space(10)
  readonly property int rowHeight: Style.space(36)

  // --- controls ------------------------------------------------------------------
  readonly property int controlHeight: Style.space(32)
  // The unit column beside numeric settings fields ("%", "°C", "ms", "min"):
  // fixed, so stacked fields line up whatever their units.
  readonly property int unitWidth: Style.space(32)
  readonly property int controlPaddingX: Style.space(10)
  readonly property int actionSize: Style.space(28)
  readonly property int iconSize: Style.space(15)
  readonly property int settingsButtonSize: Style.space(32)
  readonly property int settingsIconSize: Style.space(16)
  readonly property int headerIconSize: Style.space(18)
  readonly property real iconStroke: 1.7

  // MultiEffect, ShaderEffect and layer effects draw NOTHING under the
  // software renderer (Omarchy CPU rendering, QT_QUICK_BACKEND=software, the
  // preview harness). Gate them per item, where GraphicsInfo is available:
  //   layer.enabled: GraphicsInfo.api !== GraphicsInfo.Software
  // and keep the un-effected content readable without them.
}

// foamy-kit 0.15.1 7d0b9afb3874ce7463c04cd3e87d3740d39be4b20c9a2befbe7a231719533a0f — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Layouts

// The foamy hero band: the tinted, full-bleed area at the top of every foamy
// popup. It holds the compact title row (icon, title, meta, trailing actions,
// settings button) and, below it, the panel's hero content (a ring and
// status, a big number, artwork). Place it first in the popup body, at x 0
// and the body's full width: the popup card has padding 0, so the band runs
// to the card border and its top corners follow the popup radius.
//
//   FoamyHeroBand {
//     width: parent.width
//     iconName: "battery-charging"
//     title: FoamyI18n.t("Power")
//     meta: FoamyI18n.t("%1% · Charging", percent)
//     settingsHasCursor: cursor.at(settingsStop)
//     onSettingsClicked: root.openSettings()
//     trailing: [ FoamyAction { iconName: "refresh-cw"; … } ]
//     Row { … ring + status … }                 // hero slot (optional; a ColumnLayout:
//                                               // use Layout.fillWidth for full-width items)
//   }
//
// Settings pages use the compact form (FoamySettingsPage does it for you):
//   FoamyHeroBand { compact: true; saving: …; onBack: … }
// A sub-view built like it (an editor page) may add icon actions at the
// trailing end: compactTrailing: [ FoamyAction { iconName: "external-link"; … } ]
//
// Centred variant (a panel about one big value: clock, weather):
//   FoamyHeroBand {
//     centered: true
//     title: dateText; meta: weekText          // centred under the hero, no icon
//     Text { Layout.alignment: Qt.AlignHCenter; text: time; … }   // hero first, centred:
//                                                                  // give hero items AlignHCenter
//   }
// The buttons (trailing, ⋯, Settings) stay pinned to the trailing top corner;
// the hero and the title keep clear of them on both sides, so they stay
// centred on the band.
//
// Overflow: `menuItems`, `maxButtons`, `menuHasCursor`, `menuOpen`,
// `openMenu(keyboard)`, `menuHovered` are FoamyHeader's (at most three
// buttons top right; see FoamyHeader).
//
// Background: the foamy wash by default (FoamyPalette.band*: accent-tinted
// diagonal wash, a soft glow at the trailing top corner). A plugin may bring
// its own picture with the same geometry and text treatment:
//   imageSource: artUrl         artwork, cover-fitted and clipped to the
//                               rounded top by the band itself (any renderer)
//   background: Component {…}   e.g. a sky; sized to the band, drawn under a
//                               readability scrim; it must keep inside the
//                               rounded top itself (`topRadius` is provided)
// Field mode (search, quick add): a text field grows out of a header action
// across the title row, in place of the title and the buttons.
//
//   FoamyHeroBand {
//     id: band
//     title: FoamyI18n.t("Todoist")
//     trailing: [
//       FoamyAction { id: addAction; iconName: "plus"; onClicked: root.startAdd() },
//       FoamyAction { id: searchAction; iconName: "search"; onClicked: root.startSearch() }
//     ]
//     field: SafeTextField { id: input; … }    // the band places and sizes it
//     fieldOrigin: root.adding ? addAction : searchAction
//     fieldOpen: root.adding || root.searching
//   }
//
// - Opening, the field grows from fieldOrigin's rectangle to the full width
//   between the band's side paddings, in the title row's slot (controlHeight
//   high, centred on the row), and fades in; the title row (icon, title,
//   meta) and the buttons (trailing, ⋯, Settings) fade out. Closing plays
//   the same in reverse. FoamyMotion.grow for the growth, fadeOut/fadeIn for
//   the fades; instant under reduced motion. Mirrored in RTL (the origin is
//   where the action is; the open field is symmetric).
// - The band's height never changes: the field lies over the title row, and
//   the hero stays where it is. Field mode is for bands with a title row:
//   with no field, in the compact form or in the centred variant (its title
//   is under the hero), the band has no field mode and ignores fieldOpen.
//   An origin that is not in the row (moved into the ⋯ menu, hidden) grows
//   from the row's trailing end.
// - The band sets the field's text (and its placeholder) to
//   FoamyStyle.font.title, the size of the title it covers.
// - While fieldOpen, `buttonsActive` is false: the buttons take no pointer
//   input or focus, settingsHasCursor/menuHasCursor light nothing, and the
//   ⋯ menu closes and won't open. Drop the band's stops (Settings, ⋯,
//   trailing) from your FoamyCursor while !buttonsActive.
// - The keys are the caller's: open and close with fieldOpen, focus the
//   field when it opens (field.focusInput()) and give the focus back when it
//   closes; Esc, Enter and the rest are the field's keyPressed/accepted.
//   `fieldShown` is true while the field shows (open, or still closing);
//   `fieldProgress` runs 0 (closed) to 1 (open).
// - The field takes pointer input and focus only while fieldOpen: closing,
//   it is inert at once (a click on the fading field reaches nothing) and
//   drops the active focus if it still has it, so no key edits hidden text.
//
// The base look is a Canvas (no MultiEffect), so it is the same under the
// software renderer; it is static (no motion to reduce); it mirrors in RTL
// (glow and row follow LayoutMirroring). The bottom edge is a hairline into
// the body (`separator`).
Item {
  id: band

  // --- title row (FoamyHeader) ---------------------------------------------------
  property string iconName: ""
  property string iconGlyph: ""          // FoamyHeader.iconGlyph: a font glyph instead of iconName
  property string iconFamily: FoamyStyle.monoFamily
  property string title: ""
  property string meta: ""
  property bool showSettings: true
  property bool settingsHasCursor: false
  property alias trailing: header.trailing
  property alias settingsButton: header.settingsButton
  signal settingsClicked
  signal settingsHovered(bool hovered)

  // --- overflow menu (FoamyHeader) -------------------------------------------------
  property alias menuItems: header.menuItems
  property alias maxButtons: header.maxButtons
  property bool menuHasCursor: false
  property alias menuButton: header.menuButton
  readonly property alias menu: header.menu
  readonly property alias menuOpen: header.menuOpen
  readonly property alias overflowing: header.overflowing
  readonly property alias settingsInMenu: header.settingsInMenu
  readonly property alias shownTrailing: header.shownTrailing
  signal menuHovered(bool hovered)
  function openMenu(keyboard) {
    if (band.buttonsActive)
      header.openMenu(keyboard)
  }
  function closeMenu() {
    header.closeMenu()
  }
  function toggleMenu(keyboard) {
    if (band.buttonsActive || header.menuOpen)
      header.toggleMenu(keyboard)
  }

  // --- field mode (header: "Field mode") --------------------------------------------
  property Item field: null
  property Item fieldOrigin: null
  property bool fieldOpen: false
  readonly property bool buttonsActive: !(_fieldMode && fieldOpen)
  readonly property bool fieldShown: _fieldMode && (fieldOpen || _fieldProgress > 0)
  readonly property real fieldProgress: _fieldProgress
  readonly property bool _fieldMode: field !== null && !compact && !centered
  // Eased 0 → 1 over FoamyMotion.grow; the fades are parts of it.
  property real _fieldProgress: _fieldMode && fieldOpen ? 1 : 0
  Behavior on _fieldProgress {
    enabled: FoamyMotion.grow > 0
    NumberAnimation {
      duration: FoamyMotion.grow
      easing.type: Easing.BezierSpline
      easing.bezierCurve: FoamyMotion.easeOut
    }
  }
  // How far into the growth each fade ends (1 when there is no motion).
  readonly property real _headerFadeEnd: FoamyMotion.grow > 0 ? Math.min(1, FoamyMotion.fadeOut / FoamyMotion.grow) : 1
  readonly property real _fieldFadeEnd: FoamyMotion.grow > 0 ? Math.min(1, FoamyMotion.fadeIn / FoamyMotion.grow) : 1
  // The open field: the title row's slot between the side paddings.
  readonly property rect _fieldTo: {
    var h = Math.min(header.height, FoamyStyle.controlHeight)
    return Qt.rect(FoamyStyle.padding, header.y + (header.height - h) / 2, Math.max(0, band.width - FoamyStyle.padding * 2), h)
  }
  // The closed field: the origin action's rectangle in the band, summed up
  // the parent chain (each x, y and parent read is a binding input, so the
  // rectangle follows the row's layout). An origin outside the row grows
  // from the row's trailing end.
  readonly property rect _fieldFrom: {
    var to = band._fieldTo
    var origin = band.fieldOrigin
    if (origin && origin.visible && header.overflowTrailing.indexOf(origin) < 0) {
      let x = 0
      let y = 0
      let item = origin
      for (; item && item !== band; item = item.parent) {
        x += item.x
        y += item.y
      }
      if (item === band)
        return Qt.rect(x, y, origin.width, origin.height)
    }
    return Qt.rect(band.mirrored ? to.x : to.x + to.width - to.height, to.y, to.height, to.height)
  }
  property Item _adoptedField: null
  function _adoptField() {
    var old = band._adoptedField
    if (old && old !== band.field) {
      old.anchors.fill = undefined
      old.parent = null
    }
    band._adoptedField = band.field
    if (!band.field)
      return
    band.field.parent = fieldSlot
    band.field.anchors.fill = fieldSlot
  }
  onFieldChanged: _adoptField()
  // Any item may be the field; a text field takes the title's size.
  Binding {
    target: band.field
    property: "font.pixelSize"
    value: FoamyStyle.font.title
    when: band.field !== null && "font" in band.field
  }
  onFieldOpenChanged: if (fieldOpen)
    header.closeMenu()

  // --- centred variant -------------------------------------------------------------
  // Hero first and centred, title/meta centred under it, no icon; buttons in
  // the trailing top corner.
  property bool centered: false

  // --- compact settings form -------------------------------------------------------
  property bool compact: false
  property string compactTitle: FoamyI18n.t("Settings")
  property bool saving: false
  property alias backButton: settingsHeader.backButton
  // Icon actions at the compact form's trailing end, after "Saving…" (a
  // sub-view's "Open in …"): FoamySettingsHeader.trailing.
  property alias compactTrailing: settingsHeader.trailing
  signal back

  // --- hero slot -------------------------------------------------------------------
  default property alias hero: heroSlot.data
  // True when a hero item is shown: hidden hero children don't count (the
  // slot itself stays visible so their own `visible` is what is read).
  // While the band itself is hidden (popup closed, settings open) nothing
  // reads as shown, so it answers whether there are hero items at all.
  readonly property bool hasHero: {
    if (compact)
      return false
    var items = heroSlot.children
    if (!heroSlot.visible)
      return items.length > 0
    for (var i = 0; i < items.length; i++)
      if (items[i].visible)
        return true
    return false
  }

  // --- surface ---------------------------------------------------------------------
  property url imageSource: ""
  property Component background: null
  property bool scrim: imageSource.toString() !== "" || background !== null
  property real topRadius: FoamyStyle.bandRadius
  // When the band ends the card (empty states, a band-only popup) it rounds
  // its bottom corners like the top and drops the hairline, so it never paints
  // over the card's rounded bottom. Detected from the enclosing popup card;
  // set it yourself to override.
  property bool roundBottom: endsCard
  readonly property bool endsCard: {
    var card = band._card
    if (!card)
      return false
    band.height
    band.y
    card.height
    var bottom = band.mapToItem(card, 0, band.height).y
    return Math.abs(bottom - (card.height - card.contentBottomInset)) <= 1
  }
  property Item _card: null
  property bool separator: !roundBottom
  readonly property bool mirrored: LayoutMirroring.enabled
  readonly property Item backgroundItem: backgroundLoader.item
  readonly property alias titleRow: header
  // The picture the band's Canvas holds decoded right now ("" when none). At
  // most one: the previous one is unloaded on change, and the current one is
  // unloaded while the band is hidden (the popup is closed) or the source clears.
  readonly property string loadedImage: surface.loaded

  Component.onCompleted: {
    // The popup card: the nearest ancestor that is a BorderSurface.
    for (var item = parent; item; item = item.parent)
      if ("borderSpec" in item && "contentBottomInset" in item) {
        _card = item
        break
      }
    if (field !== _adoptedField)
      _adoptField()
  }

  implicitWidth: FoamyStyle.popupWidth
  implicitHeight: FoamyStyle.bandPaddingTop + Math.max(content.implicitHeight, compact ? 0 : header.implicitHeight) + FoamyStyle.bandPaddingBottom

  Loader {
    id: backgroundLoader
    anchors.fill: parent
    active: band.background !== null
    sourceComponent: band.background
  }

  Canvas {
    id: surface
    objectName: "foamyHeroBandSurface"
    anchors.fill: parent
    property color fill: FoamyPalette.bandFill
    property color fillEnd: FoamyPalette.bandFillEnd
    property color glow: FoamyPalette.bandGlow
    property color scrimTop: FoamyPalette.bandScrimTop
    property color scrimBottom: FoamyPalette.bandScrimBottom
    // Only load a picture while the band is shown.
    readonly property string image: band.visible ? band.imageSource.toString() : ""
    property string loaded: ""
    readonly property real radius: Math.max(0, Math.min(band.topRadius, width / 2, height))
    readonly property real bottomRadius: band.roundBottom ? Math.max(0, Math.min(band.topRadius, width / 2, height / 2)) : 0
    onBottomRadiusChanged: requestPaint()

    onFillChanged: requestPaint()
    onFillEndChanged: requestPaint()
    onGlowChanged: requestPaint()
    onScrimTopChanged: requestPaint()
    onRadiusChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onImageChanged: {
      if (loaded !== "" && loaded !== image)
        unloadImage(loaded)
      loaded = image
      if (image !== "")
        loadImage(image)
      requestPaint()
    }
    Component.onDestruction: if (loaded !== "")
      unloadImage(loaded)
    onImageLoaded: requestPaint()
    Connections {
      target: band
      function onMirroredChanged() {
        surface.requestPaint()
      }
      function onScrimChanged() {
        surface.requestPaint()
      }
      function onBackgroundChanged() {
        surface.requestPaint()
      }
    }

    function roundedTop(ctx) {
      var r = radius
      ctx.beginPath()
      ctx.moveTo(r, 0)
      ctx.lineTo(width - r, 0)
      ctx.arcTo(width, 0, width, r, r)
      var b = bottomRadius
      ctx.lineTo(width, height - b)
      ctx.arcTo(width, height, width - b, height, b)
      ctx.lineTo(b, height)
      ctx.arcTo(0, height, 0, height - b, b)
      ctx.lineTo(0, r)
      ctx.arcTo(0, 0, r, 0, r)
      ctx.closePath()
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (width <= 0 || height <= 0)
        return
      roundedTop(ctx)
      ctx.clip()
      var picture = image !== "" && isImageLoaded(image)
      if (picture) {
        // Cover-fit the picture into the band.
        var natural = {
          w: width,
          h: height
        }
        try {
          var data = ctx.createImageData(image)
          natural = {
            w: data.width,
            h: data.height
          }
        } catch (error) {
          natural = {
            w: width,
            h: height
          }
        }
        var scale = Math.max(width / Math.max(1, natural.w), height / Math.max(1, natural.h))
        var w = natural.w * scale, h = natural.h * scale
        ctx.drawImage(image, (width - w) / 2, (height - h) / 2, w, h)
      } else if (band.background === null) {
        var wash = ctx.createLinearGradient(band.mirrored ? width : 0, 0, band.mirrored ? width * 0.4 : width * 0.6, height)
        wash.addColorStop(0, fill)
        wash.addColorStop(1, fillEnd)
        ctx.fillStyle = wash
        ctx.fillRect(0, 0, width, height)
        var gx = band.mirrored ? width * 0.1 : width * 0.9
        var halo = ctx.createRadialGradient(gx, 0, 0, gx, 0, Math.max(width, height) * 0.75)
        halo.addColorStop(0, glow)
        halo.addColorStop(1, Qt.rgba(glow.r, glow.g, glow.b, 0))
        ctx.fillStyle = halo
        ctx.fillRect(0, 0, width, height)
      }
      if (band.scrim && (picture || band.background !== null)) {
        var veil = ctx.createLinearGradient(0, 0, 0, height)
        veil.addColorStop(0, scrimTop)
        veil.addColorStop(1, scrimBottom)
        ctx.fillStyle = veil
        ctx.fillRect(0, 0, width, height)
      }
    }
  }

  Column {
    id: content
    y: FoamyStyle.bandPaddingTop
    width: parent.width
    spacing: band.hasHero ? (band.centered ? FoamyStyle.gap : FoamyStyle.bandGap) : 0

    // Room for the title row (FoamyHeader, below: it sits over the band so the
    // centred variant can pin its buttons to the corner).
    Item {
      id: headerSlot
      visible: !band.compact && !band.centered
      width: parent.width
      height: header.implicitHeight
    }

    FoamySettingsHeader {
      id: settingsHeader
      visible: band.compact
      width: parent.width
      topPadding: 0
      bottomPadding: 0
      title: band.compactTitle
      saving: band.saving
      onBack: band.back()
    }

    // A layout, so hero items align to the reading start in RTL too. Give
    // full-width hero content Layout.fillWidth: true (centred: AlignHCenter).
    ColumnLayout {
      id: heroSlot
      // Always "visible" outside the compact form (zero height when empty),
      // so hasHero can read its children's own visibility.
      visible: !band.compact
      x: band.centered ? band.centeredInset : FoamyStyle.padding
      width: Math.max(0, parent.width - x * 2)
      spacing: FoamyStyle.gap
    }

    // Centred title and meta (centred variant).
    Column {
      id: centeredTitle
      objectName: "foamyHeroBandCenteredTitle"
      visible: band.centered && !band.compact && (band.title !== "" || band.meta !== "")
      x: band.centeredInset
      width: Math.max(0, parent.width - x * 2)
      spacing: FoamyStyle.gapTiny
      Text {
        width: parent.width
        visible: band.title !== ""
        text: band.title
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        color: FoamyPalette.text
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.title
        font.weight: Font.DemiBold
      }
      Text {
        width: parent.width
        visible: band.meta !== ""
        text: band.meta
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        color: FoamyPalette.secondaryText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.bodySmall
      }
    }
  }

  // Centred content keeps the same distance from both sides, clear of the
  // corner buttons, so it stays centred on the band.
  readonly property real centeredInset: FoamyStyle.padding + (header.buttonsWidth > 0 ? header.buttonsWidth + FoamyStyle.gap : 0)

  FoamyHeader {
    id: header
    visible: !band.compact
    // Field mode: faded out and inert while the field is open.
    enabled: band.buttonsActive
    opacity: 1 - Math.min(1, band._fieldProgress / band._headerFadeEnd)
    y: FoamyStyle.bandPaddingTop
    width: parent.width
    height: implicitHeight
    topPadding: 0
    bottomPadding: 0
    showTitle: !band.centered
    iconName: band.iconName
    iconGlyph: band.iconGlyph
    iconFamily: band.iconFamily
    title: band.title
    meta: band.meta
    showSettings: band.showSettings
    settingsHasCursor: band.settingsHasCursor && band.buttonsActive
    menuHasCursor: band.menuHasCursor && band.buttonsActive
    onSettingsClicked: band.settingsClicked()
    onSettingsHovered: function (hovered) {
      band.settingsHovered(hovered)
    }
    onMenuHovered: function (hovered) {
      band.menuHovered(hovered)
    }
  }

  // Field mode: the caller's field, over the title row, between its closed
  // (the origin action) and open rectangles.
  Item {
    id: fieldSlot
    objectName: "foamyHeroBandField"
    visible: band.fieldShown
    // Inert from the moment it starts closing: Qt drops the active focus of
    // a disabled item, and a click can't hand it back while the field fades.
    enabled: band._fieldMode && band.fieldOpen
    opacity: Math.min(1, band._fieldProgress / band._fieldFadeEnd)
    readonly property real t: band._fieldProgress
    x: band._fieldFrom.x + (band._fieldTo.x - band._fieldFrom.x) * t
    y: band._fieldFrom.y + (band._fieldTo.y - band._fieldFrom.y) * t
    width: band._fieldFrom.width + (band._fieldTo.width - band._fieldFrom.width) * t
    height: band._fieldFrom.height + (band._fieldTo.height - band._fieldFrom.height) * t
  }

  Rectangle {
    objectName: "foamyHeroBandEdge"
    visible: band.separator
    anchors.bottom: parent.bottom
    width: parent.width
    height: 1
    color: FoamyPalette.bandEdge
  }
}

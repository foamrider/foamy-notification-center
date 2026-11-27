pragma Singleton
// foamy-kit 0.16.0 ef4882d76a20b9a897c574e949d0a94292d57265201d15ec86bc93bdb15edc05 — do not edit; change foamy-kit and run sync
import QtQuick
import Quickshell.Io
import qs.Commons as Commons

// Foamy colours. Surface roles come from Commons.Color (always qualified);
// status colours (warning/success/error/info) come from the current theme's
// colors.toml (yellow/green/red/cyan), so they match whatever theme is set
// instead of a hardcoded Catppuccin or Nord value. Missing keys fall back to
// Commons.Color.urgent/accent. Hex literals are allowed only in this file.
QtObject {
  id: root

  // --- surface roles -------------------------------------------------------------
  readonly property color background: Commons.Color.popups.background
  readonly property color text: Commons.Color.popups.text
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  // Secondary text (meta, section labels) and muted text (hints, empty states).
  // In light themes the tints .72 and .55 are too faint for small text in
  // some themes (secondary 3.49:1 and muted 2.47:1 in Rosé Pine), so each
  // darkens to the lightest tint that reaches its ratio on the surface:
  // muted 4.5:1 (WCAG AA), secondary 5.5:1, so muted stays the lighter one.
  // Muted: .55 White, .58 Flexoki Light, .62 Lupine, .82 Catppuccin Latte,
  // .84 Rosé Pine. Secondary: .72, but .90 Catppuccin Latte and .93 Rosé
  // Pine. Dark themes keep .72 and .55. Each stops at a ceiling, so a theme
  // whose text is weak keeps three tones (muted below .85 of the way to the
  // text, as a field's placeholder must be) and stays under its ratio there.
  readonly property color secondaryText: lightTheme ? readableTint(0.72, 5.5, 0.95) : Qt.tint(background, Qt.alpha(text, 0.72))
  readonly property color mutedText: lightTheme ? readableTint(0.55, 4.5, 0.84) : Qt.tint(background, Qt.alpha(text, 0.55))
  readonly property color border: Qt.alpha(text, 0.15)
  readonly property color divider: Qt.alpha(text, 0.12)
  readonly property color hoverFill: Qt.alpha(text, 0.08)
  readonly property color fieldFill: Qt.alpha(text, 0.055)
  readonly property color selectedFill: Qt.alpha(accent, 0.18)
  // Menus (FoamyMenu) sit one step above the card they drop over: in a
  // light theme lighter than the card, with a clearer edge (no shadow
  // draws there to set them apart).
  readonly property color menuFill: lightTheme ? Qt.tint(background, Qt.alpha("#ffffff", 0.7)) : Qt.tint(background, Qt.alpha(text, 0.035))
  readonly property color menuBorder: lightTheme ? Qt.alpha(text, 0.40) : border
  // Inline help notes (FoamyInfoNote): a subtle surface under a heading.
  readonly property color noteFill: Qt.alpha(text, 0.045)
  // Text on an accent fill (FoamyButton primary): the popup's text or its
  // background, whichever reads better on the accent (a mid-tone accent
  // can go either way, so measured, not guessed from its brightness). Not
  // `onAccent`: QML takes an `on` + capital name for a signal handler, and
  // such a property never had a colour (primary labels were black).
  readonly property color accentInk: contrastRatio(text, accent) >= contrastRatio(background, accent) ? text : background

  // --- hero band (FoamyHeroBand) ---------------------------------------------------
  // The foamy header band: the popup surface tinted toward the accent, from
  // the dev-era headers (power 0.075, audio/github/weather 0.08 + glow, NC
  // 0.12 -> 0.035). A diagonal wash from bandFill to bandFillEnd, a soft
  // accent glow at the trailing top corner, a hairline into the body.
  readonly property color bandFill: Qt.tint(background, Qt.alpha(accent, lightTheme ? 0.11 : 0.09))
  readonly property color bandFillEnd: Qt.tint(background, Qt.alpha(accent, lightTheme ? 0.05 : 0.04))
  readonly property color bandGlow: Qt.alpha(accent, lightTheme ? 0.10 : 0.14)
  readonly property color bandEdge: Qt.alpha(text, lightTheme ? 0.10 : 0.08)
  // Over pictures (artwork, sky): keeps band text readable.
  readonly property color bandScrimTop: Qt.alpha(background, lightTheme ? 0.45 : 0.35)
  readonly property color bandScrimBottom: Qt.alpha(background, lightTheme ? 0.82 : 0.78)

  // --- theme status colours ------------------------------------------------------
  readonly property string themePath: (Commons.Color.currentThemePath || "") + "/colors.toml"
  readonly property var theme: parse(colorsFile.text())
  readonly property bool lightTheme: theme.mode === "light" || (theme.mode !== "dark" && luminance(background) > 0.5)
  readonly property color warning: pick(["yellow", "bright_yellow", "orange"], urgent)
  readonly property color success: pick(["green", "bright_green"], accent)
  readonly property color error: pick(["red", "bright_red"], urgent)
  readonly property color info: pick(["cyan", "blue"], accent)

  function pick(keys, fallback) {
    for (var i = 0; i < keys.length; i++) {
      var value = theme[keys[i]]
      if (typeof value === "string" && /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(value))
        return value
    }
    return fallback
  }

  // Flat `key = "value"` lines; sections and anything else are ignored.
  function parse(raw) {
    var out = ({})
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]*)"\s*(#.*)?$/.exec(lines[i])
      if (match)
        out[match[1]] = match[2]
    }
    return out
  }

  function luminance(c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
  }

  // WCAG 2 contrast ratio of two opaque colours (1 to 21).
  function contrastRatio(a, b) {
    function channel(v) {
      return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    }
    function relative(c) {
      return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }
    var la = relative(a), lb = relative(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  }

  // The lightest tint of `text` over `background`, from `alpha` up to
  // `limit` in steps of .01, with at least `ratio` contrast on `background`;
  // the tint at `limit` when none reaches it.
  function readableTint(alpha, ratio, limit) {
    const last = Math.round(limit * 100)
    for (let step = Math.round(alpha * 100); step < last; step++) {
      const tint = Qt.tint(background, Qt.alpha(text, step / 100))
      if (contrastRatio(tint, background) >= ratio)
        return tint
    }
    return Qt.tint(background, Qt.alpha(text, last / 100))
  }

  // Status colour readable on the popup surface, for text and thin marks
  // (rings, icons). It darkens (light theme) or lightens (dark theme) in
  // steps only until it reaches 4.5:1 on the popup background, so a colour
  // that already reads keeps the theme's hue and a faint one (a yellow on
  // white, a dim red on a dark fill) moves as far as it must. Large fills
  // (bars) use the raw colour.
  // `surface`: what it is drawn on, when not the popup background (a tinted
  // fill: give the opaque colour as it shows).
  function onSurface(c, surface) {
    // A colour given as text ("#d20f39") is read as one first.
    const base = Qt.color(c)
    const under = surface === undefined ? background : Qt.color(surface)
    let out = base
    // Measured as drawn: rounded to 8 bits a channel (unrounded, a step
    // can pass at 4.50 and draw at 4.49).
    // At most 1.7 times darker or lighter: a very light colour (yellow on
    // white) or a very dark one can stay under 4.5:1 there. Qt.lighter
    // raises the HSV value and, once that is full, lowers the saturation,
    // so a bright red stays red (Catppuccin #f38ba8 -> #ff92b0).
    for (let step = 1; step <= 14 && contrastRatio(out, under) < 4.5; step++) {
      const factor = 1 + step * 0.05
      out = Qt.color((lightTheme ? Qt.darker(base, factor) : Qt.lighter(base, factor)).toString())
    }
    return out
  }

  property FileView colorsFile: FileView {
    path: root.themePath
    watchChanges: true
    printErrors: false
    blockLoading: true
    onFileChanged: reload()
  }
}

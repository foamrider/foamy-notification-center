pragma Singleton
// foamy-kit 0.3.0 7351706e3bff0b8e5f0a9c0fc1459c006db74672dff30c275b4ca1df5d312c18 — do not edit; change foamy-kit and run sync
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
  readonly property color secondaryText: Qt.tint(background, Qt.alpha(text, 0.72))
  readonly property color mutedText: Qt.tint(background, Qt.alpha(text, 0.55))
  readonly property color border: Qt.alpha(text, 0.15)
  readonly property color divider: Qt.alpha(text, 0.12)
  readonly property color hoverFill: Qt.alpha(text, 0.08)
  readonly property color fieldFill: Qt.alpha(text, 0.055)
  readonly property color selectedFill: Qt.alpha(accent, 0.18)

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
      if (typeof value === "string" && /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(value)) return value
    }
    return fallback
  }

  // Flat `key = "value"` lines; sections and anything else are ignored.
  function parse(raw) {
    var out = ({})
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]*)"\s*(#.*)?$/.exec(lines[i])
      if (match) out[match[1]] = match[2]
    }
    return out
  }

  function luminance(c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
  }

  // Status colour readable on the popup surface, for text.
  function onSurface(c) {
    return lightTheme ? Qt.darker(c, 1.35) : c
  }

  property FileView colorsFile: FileView {
    path: root.themePath
    watchChanges: true
    printErrors: false
    blockLoading: true
    onFileChanged: reload()
  }
}

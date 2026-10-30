// foamy-kit 0.1.0 6b5d1d4d51296570b527741139fad823278031100b9b6c4d4c4f2b0464d640e9 — do not edit; change foamy-kit and run sync
import QtQuick

// Foamy icon set: inline Lucide SVG paths (ISC, see LICENSE-LUCIDE), the
// union of every foamy plugin's icon table, drawn with the foamy stroke and
// recoloured to follow the theme. Unknown names draw "settings".
//
//   FoamyIcon { name: "refresh-cw"; color: FoamyPalette.text; width: FoamyStyle.iconSize; height: width }
//
// Directional icons (arrow-left, chevron-right, …) mirror in right-to-left
// languages. Add icons here, never in a plugin.
Image {
  id: root
  property string name: "settings"
  property color color: FoamyPalette.text
  property real strokeWidth: FoamyStyle.iconStroke
  readonly property bool known: paths.hasOwnProperty(name)
  readonly property var directional: ["arrow-left", "arrow-right", "back", "chevron", "chevron-left", "chevron-right", "external-link"]
  readonly property var paths: ({
    "activity": "<path d=\"M22 12h-4l-3 9L9 3l-3 9H2\"/>",
    "airplay": "<path d=\"M5 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-1\"/><path d=\"m12 15 7 7H5z\"/>",
    "alert": "<path d=\"M12 3 2 21h20Z M12 9v5M12 17h.01\"/>",
    "app-window": "<rect x=\"2\" y=\"4\" width=\"20\" height=\"16\" rx=\"2\"/><path d=\"M2 8h20M6 4v4\"/>",
    "arrow-left": "<path d=\"m12 19-7-7 7-7M5 12h14\"/>",
    "back": "<path d=\"m11 5-7 7 7 7M4 12h16\"/>",
    "box": "<path d=\"m12 3 9 5v8l-9 5-9-5V8l9-5ZM3 8l9 5 9-5M12 13v8M7.5 5.5l9 5\"/>",
    "cancelled": "<circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"m9 9 6 6m0-6-6 6\"/>",
    "check": "<path d=\"m20 6-11 11-5-5\"/>",
    "chevron": "<path d=\"m9 5 7 7-7 7\"/>",
    "chevron-down": "<path d=\"m6 9 6 6 6-6\"/>",
    "chevron-right": "<path d=\"m9 6 6 6-6 6\"/>",
    "chevron-up": "<path d=\"m6 15 6-6 6 6\"/>",
    "cloud": "<path d=\"M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z\"></path>",
    "cloud-drizzle": "<path d=\"M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242\"></path><path d=\"M8 19v1\"></path><path d=\"M8 14v1\"></path><path d=\"M16 19v1\"></path><path d=\"M16 14v1\"></path><path d=\"M12 21v1\"></path><path d=\"M12 16v1\"></path>",
    "cloud-fog": "<path d=\"M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242\"></path><path d=\"M16 17H7\"></path><path d=\"M17 21H9\"></path>",
    "cloud-lightning": "<path d=\"M6 16.326A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 .5 8.973\"></path><path d=\"m13 12-3 5h4l-3 5\"></path>",
    "cloud-moon": "<path d=\"M13 16a3 3 0 0 1 0 6H7a5 5 0 1 1 4.9-6z\"></path><path d=\"M18.376 14.512a6 6 0 0 0 3.461-4.127c.148-.625-.659-.97-1.248-.714a4 4 0 0 1-5.259-5.26c.255-.589-.09-1.395-.716-1.248a6 6 0 0 0-4.594 5.36\"></path>",
    "cloud-rain": "<path d=\"M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242\"></path><path d=\"M16 14v6\"></path><path d=\"M8 14v6\"></path><path d=\"M12 16v6\"></path>",
    "cloud-rain-wind": "<path d=\"M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242\"></path><path d=\"m9.2 22 3-7\"></path><path d=\"m9 13-3 7\"></path><path d=\"m17 13-3 7\"></path>",
    "cloud-snow": "<path d=\"M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242\"></path><path d=\"M8 15h.01\"></path><path d=\"M8 19h.01\"></path><path d=\"M12 17h.01\"></path><path d=\"M12 21h.01\"></path><path d=\"M16 15h.01\"></path><path d=\"M16 19h.01\"></path>",
    "cloud-sun": "<path d=\"M12 2v2\"></path><path d=\"m4.93 4.93 1.41 1.41\"></path><path d=\"M20 12h2\"></path><path d=\"m19.07 4.93-1.41 1.41\"></path><path d=\"M15.947 12.65a4 4 0 0 0-5.925-4.128\"></path><path d=\"M13 22H7a5 5 0 1 1 4.9-6H13a3 3 0 0 1 0 6Z\"></path>",
    "cpu": "<rect x=\"4\" y=\"4\" width=\"16\" height=\"16\" rx=\"2\"/><rect x=\"9\" y=\"9\" width=\"6\" height=\"6\"/><path d=\"M9 1v3M15 1v3M9 20v3M15 20v3M20 9h3M20 15h3M1 9h3M1 15h3\"/>",
    "devices": "<rect x=\"2\" y=\"3\" width=\"14\" height=\"12\" rx=\"1\"/><path d=\"M9 15v5M5 20h8\"/><rect x=\"17\" y=\"9\" width=\"5\" height=\"12\" rx=\"1\"/>",
    "disconnected": "<path d=\"m4 4 16 16M8 3v4m8-4v4M6 7h12v4a6 6 0 0 1-6 6v5M6 11a6 6 0 0 0 2 4\"/>",
    "download": "<path d=\"M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5\"/>",
    "droplet": "<path d=\"M12 22a7 7 0 0 0 7-7c0-2-1-3.9-3-5.5s-3.5-4-4-6.5c-.5 2.5-2 4.9-4 6.5C6 11.1 5 13 5 15a7 7 0 0 0 7 7z\"></path>",
    "droplets": "<path d=\"M7 16.3c2.2 0 4-1.83 4-4.05 0-1.16-.57-2.26-1.71-3.19S7.29 6.75 7 5.3c-.29 1.45-1.14 2.84-2.29 3.76S3 11.1 3 12.25c0 2.22 1.8 4.05 4 4.05z\"></path><path d=\"M12.56 6.6A10.97 10.97 0 0 0 14 3.02c.5 2.5 2 4.9 4 6.5s3 3.5 3 5.5a6.98 6.98 0 0 1-11.91 4.97\"></path>",
    "external": "<path d=\"M14 3h7v7m0-7L10 14M10 3H4a1 1 0 0 0-1 1v16a1 1 0 0 0 1 1h16a1 1 0 0 0 1-1v-6\"/>",
    "external-link": "<path d=\"M15 3h6v6M10 14 21 3M21 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5\"/>",
    "folder": "<path d=\"M3 7V5h6l2 2h10v13H3Z\"/>",
    "gauge": "<path d=\"m12 14 4-4M3.3 19a10 10 0 1 1 17.4 0Z\"/>",
    "globe": "<circle cx=\"12\" cy=\"12\" r=\"9\"/><ellipse cx=\"12\" cy=\"12\" rx=\"4\" ry=\"9\"/><path d=\"M3 12h18\"/>",
    "headphones": "<path d=\"M3 14v-3a9 9 0 0 1 18 0v3\"/><rect x=\"3\" y=\"12\" width=\"4\" height=\"9\" rx=\"2\"/><rect x=\"17\" y=\"12\" width=\"4\" height=\"9\" rx=\"2\"/>",
    "info": "<path d=\"M3 11v2a2 2 0 0 0 2 2h3l11 4V5L8 9H5a2 2 0 0 0-2 2Zm4 4 2 6h3l-2-5M8 9v6\"/>",
    "laptop": "<rect x=\"4\" y=\"3\" width=\"16\" height=\"12\" rx=\"2\"/><path d=\"m4 15-2 6h20l-2-6\"/>",
    "leaf": "<path d=\"M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.5 19 2c1 2 2 4.2 2 8 0 5.5-4.8 10-10 10ZM2 22c0-6 6-11 11-14\"/>",
    "map-pin": "<path d=\"M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0\"></path><circle cx=\"12\" cy=\"10\" r=\"3\"></circle>",
    "mic": "<rect x=\"9\" y=\"2\" width=\"6\" height=\"12\" rx=\"3\"/><path d=\"M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8\"/>",
    "mic-off": "<path d=\"m2 2 20 20M9 9v3a3 3 0 0 0 5.12 2.12M15 9.34V5a3 3 0 0 0-5.94-.6M5 10v2a7 7 0 0 0 12 4.9M19 10v2a7 7 0 0 1-.3 2M12 19v3M8 22h8\"/>",
    "monitor": "<rect x=\"2\" y=\"3\" width=\"20\" height=\"14\" rx=\"2\"/><path d=\"M8 21h8M12 17v4\"/>",
    "moon": "<path d=\"M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401\"></path>",
    "pause": "<rect x=\"6\" y=\"4\" width=\"4\" height=\"16\" rx=\"1\"/><rect x=\"14\" y=\"4\" width=\"4\" height=\"16\" rx=\"1\"/>",
    "pencil": "<path d=\"m16 3 5 5L8 21H3v-5Z M14 5l5 5\"/>",
    "play": "<path d=\"m7 4 13 8-13 8Z\"/>",
    "plug": "<path d=\"M12 22v-5M9 8V2M15 8V2M7 8h10v4a5 5 0 0 1-10 0Z\"/>",
    "plus": "<path d=\"M12 5v14M5 12h14\"/>",
    "refresh": "<path d=\"M20 7v5h-5M4 17v-5h5\"/><path d=\"M6.1 6.1A8 8 0 0 1 20 12M4 12a8 8 0 0 0 13.9 5.9\"/>",
    "refresh-cw": "<path d=\"M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8\"></path><path d=\"M21 3v5h-5\"></path><path d=\"M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16\"></path><path d=\"M8 16H3v5\"></path>",
    "scale": "<path d=\"m16 16 3-8 3 8c-1.7 1.3-4.3 1.3-6 0ZM2 16l3-8 3 8c-1.7 1.3-4.3 1.3-6 0ZM7 21h10M12 3v18M3 7l3-1c4 1 8 1 12-1l3 1\"/>",
    "scan": "<path d=\"M8 3H5a2 2 0 0 0-2 2v3m13-5h3a2 2 0 0 1 2 2v3M3 16v3a2 2 0 0 0 2 2h3m13-5v3a2 2 0 0 1-2 2h-3\"/>",
    "server": "<rect x=\"2\" y=\"3\" width=\"20\" height=\"7\" rx=\"2\"/><rect x=\"2\" y=\"14\" width=\"20\" height=\"7\" rx=\"2\"/><path d=\"M6 6.5h.01M6 17.5h.01\"/>",
    "settings": "<path d=\"m10 3-.6 2.3-2 .9-2.1-.7-2 3.5 1.6 1.7v2.6L3.3 15l2 3.5 2.1-.7 2 .9L10 21h4l.6-2.3 2-.9 2.1.7 2-3.5-1.6-1.7v-2.6L20.7 9l-2-3.5-2.1.7-2-.9L14 3Z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/>",
    "smartphone": "<rect x=\"6\" y=\"2\" width=\"12\" height=\"20\" rx=\"2\"/><path d=\"M12 18h.01\"/>",
    "speaker": "<rect x=\"4\" y=\"2\" width=\"16\" height=\"20\" rx=\"2\"/><circle cx=\"12\" cy=\"14\" r=\"4\"/><circle cx=\"12\" cy=\"6\" r=\"1\"/>",
    "sun": "<circle cx=\"12\" cy=\"12\" r=\"4\"></circle><path d=\"M12 2v2\"></path><path d=\"M12 20v2\"></path><path d=\"m4.93 4.93 1.41 1.41\"></path><path d=\"m17.66 17.66 1.41 1.41\"></path><path d=\"M2 12h2\"></path><path d=\"M20 12h2\"></path><path d=\"m6.34 17.66-1.41 1.41\"></path><path d=\"m19.07 4.93-1.41 1.41\"></path>",
    "swap": "<path d=\"M4 7h16m-4-4 4 4-4 4M20 17H4m4-4-4 4 4 4\"/>",
    "sync": "<path d=\"M20 9a8 8 0 0 0-14-3L3 9m0-5v5h5M4 15a8 8 0 0 0 14 3l3-3m0 5v-5h-5\"/>",
    "tablet": "<rect x=\"4\" y=\"2\" width=\"16\" height=\"20\" rx=\"2\"/><path d=\"M12 18h.01\"/>",
    "terminal": "<path d=\"m4 17 6-5-6-5M12 19h8\"/>",
    "train": "<rect x=\"5\" y=\"2\" width=\"14\" height=\"17\" rx=\"4\"/><path d=\"M5 10h14M12 2v8M8 19l-2 3m10-3 2 3\"/><path d=\"M8 15h.01M16 15h.01\"/>",
    "trash": "<path d=\"M3 6h18M9 6V4h6v2M5 6l1 14h12l1-14M10 10v6M14 10v6\"/>",
    "triangle-alert": "<path d=\"m10.3 3.9-8.1 14a2 2 0 0 0 1.7 3h16.2a2 2 0 0 0 1.7-3l-8.1-14a2 2 0 0 0-3.4 0M12 9v4M12 17h.01\"/>",
    "unlink": "<path d=\"m8 3 1 3M3 8l3 1m10 12-1-3m6-2-3-1M10 14l-2 2a4 4 0 0 1-6-6l2-2m10 2 2-2a4 4 0 0 1 6 6l-2 2M3 3l18 18\"/>",
    "volume-2": "<path d=\"m11 5-6 4H2v6h3l6 4zM15.5 8.5a5 5 0 0 1 0 7M19 5a10 10 0 0 1 0 14\"/>",
    "volume-x": "<path d=\"m11 5-6 4H2v6h3l6 4zM17 9l6 6M23 9l-6 6\"/>",
    "warning": "<path d=\"m10.3 3.9-8 14a2 2 0 0 0 1.7 3h16a2 2 0 0 0 1.7-3l-8-14a2 2 0 0 0-3.4 0Z\"/><path d=\"M12 9v4m0 4h.01\"/>",
    "watch": "<rect x=\"5\" y=\"6\" width=\"14\" height=\"12\" rx=\"3\"/><path d=\"m9 6 1-4h4l1 4M9 18l1 4h4l1-4M12 9v3l2 1\"/>",
    "wind": "<path d=\"M12.8 19.6A2 2 0 1 0 14 16H2\"></path><path d=\"M17.5 8a2.5 2.5 0 1 1 2 4H2\"></path><path d=\"M9.8 4.4A2 2 0 1 1 11 8H2\"></path>"
  })
  width: FoamyStyle.iconSize
  height: width
  mirror: FoamyI18n.rightToLeft && directional.indexOf(name) !== -1
  sourceSize.width: Math.ceil(width * 2)
  sourceSize.height: Math.ceil(height * 2)
  fillMode: Image.PreserveAspectFit
  // Inline SVG keeps the original stroke geometry and follows the active theme.
  source: "data:image/svg+xml;charset=utf-8," + encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="'
    + color.toString() + '" stroke-width="' + strokeWidth
    + '" stroke-linecap="round" stroke-linejoin="round">'
    + (paths[name] || paths.settings) + '</svg>')
}

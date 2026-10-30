// foamy-kit 0.3.4 14efba34cad6934207d57ef1dc27759eb9049cd049ec1fdf17da635487d3dd93 — do not edit; change foamy-kit and run sync
import QtQuick
import qs.Commons as Commons
import qs.Ui

// The settings toggle row: the stock Toggle (cursor/focus states, switch
// track, 4.5 reduced motion) in the foamy radius and font.
//
//   FoamyToggle { width: parent.width; label: FoamyI18n.t("Show … in the bar"); checked: root.showX; onClicked: root.save("showX", !checked) }
Toggle {
  radius: FoamyStyle.radius
  fontFamily: FoamyStyle.fontFamily
  foreground: Commons.Color.popups.text
  titleSize: FoamyStyle.font.subtitle
  descriptionSize: FoamyStyle.font.caption
}

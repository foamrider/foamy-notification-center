// These are the controls shown in the center. Center settings save through
// kit/FoamyPrefs.js; popup settings are owned and written by Foamy Notifications
// (asked over its `setPreference` IPC).
var centerFields = [
  {key:"browserGrouping",type:"enum",label:"Group browser notifications by",defaultValue:"browser",options:["browser","hostname","none"]},
  {key:"useBrowserFavicons",type:"boolean",label:"Use website favicons",defaultValue:true},
  {key:"compact",type:"boolean",label:"Compact view",defaultValue:false},
  {key:"showPreview",type:"boolean",label:"Show pictures",defaultValue:true},
  {key:"keepDays",type:"integer",label:"Keep notifications (days)",defaultValue:30,min:1,max:365},
  {key:"maxItems",type:"integer",label:"Maximum notifications",defaultValue:1000,min:50,max:10000}
]
var popupFields = [
  {key:"offerSnoozeWhenSharing",type:"boolean",label:"Offer snooze when sharing the screen",defaultValue:true},
  {key:"dndSilenceCritical",type:"boolean",label:"Do not disturb also silences critical alerts",defaultValue:false},
  {key:"groupDuplicates",type:"boolean",label:"Group duplicate notifications",defaultValue:true},
  {key:"useBrowserFavicons",type:"boolean",label:"Use website favicons",defaultValue:true},
  {key:"compact",type:"boolean",label:"Compact view",defaultValue:true},
  {key:"showImages",type:"boolean",label:"Show pictures",defaultValue:true},
  {key:"closeButtonRemovesHistory",type:"boolean",label:"X removes from history",defaultValue:false},
  {key:"normalTimeoutSec",type:"integer",label:"Normal notification duration (seconds)",defaultValue:8,min:1,max:120}
]
function field(scope,key) {
  return (scope === "center" ? centerFields : scope === "popups" ? popupFields : []).find(function(f) { return f.key === key }) || null
}
function valid(scope,key,value) {
  var f = field(scope,key)
  if (!f) return false
  if (f.type === "boolean") return typeof value === "boolean"
  if (f.type === "enum") return typeof value === "string" && f.options.indexOf(value) >= 0
  return typeof value === "number" && isFinite(value) && Math.floor(value) === value && value >= f.min && value <= f.max
}
function value(scope,settings,key) {
  var f = field(scope,key)
  return f ? settings && valid(scope,key,settings[key]) ? settings[key] : f.defaultValue : undefined
}
function optionLabel(option) { return {browser:"Browser",hostname:"Hostname",none:"Do not group"}[option] || option }
if (typeof module !== "undefined") module.exports = {centerFields:centerFields,popupFields:popupFields,field:field,valid:valid,value:value,optionLabel:optionLabel}

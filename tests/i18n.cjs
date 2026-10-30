// Exercise the real QML substitution function with catalog data in pure model tests.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../kit/FoamyI18n.qml'), 'utf8');
// The kit's FoamyI18n (kit/): englishText, substitute, t, tn and number.
const start = source.indexOf('  function englishText(');
const end = source.lastIndexOf('\n}');
const scope = vm.createContext({backend: null, english: {}});
scope.root = scope;
vm.runInContext(source.slice(start, end), scope);
const en = require('../i18n/en.json');
const no = require('../i18n/no.json');
function text(key, language, values) {
  const catalog = language === 'no' || language === 'nb' ? no : en;
  scope.backend = {number(value) { return new Intl.NumberFormat(language === "nb" ? "no" : language).format(value); }, t(label, fallback) { return Object.hasOwn(catalog, label) ? catalog[label] : fallback; }};
  return scope.t(key, values);
}
module.exports = {text, no, en, norwegian: no, nb: no};

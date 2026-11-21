// The kit's FoamyI18n string work (kit/FoamyI18nText.js, which the QML
// singleton calls) over this plugin's catalogs, for pure model tests.
const I18n = require('../kit/node-loader.cjs').load('FoamyI18nText');
const en = require('../i18n/en.json');
const no = require('../i18n/no.json');
function text(key, language, values) {
  const catalog = language === 'no' ? no : en;
  const number = value => new Intl.NumberFormat(language).format(value);
  return I18n.translator(catalog, en, number).t(key, values);
}
module.exports = {text, no, en};

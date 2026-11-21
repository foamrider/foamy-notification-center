const assert = require('node:assert/strict');
const test = require('node:test');
const I = require('./i18n.cjs');
const Preferences = require('../Preferences.js');
const manifest = require('../manifest.json');
const tokens = s => [...s.matchAll(/%[1-9][0-9]*|\{\w+\}/g)].map(m => m[0]).sort();

test('the Norwegian catalog has every English entry with the same placeholders', () => {
  for (const [key, value] of Object.entries(I.en)) {
    assert.ok(Object.hasOwn(I.no, key), `missing Norwegian entry: ${key}`);
    const translated = I.no[key];
    if (value && typeof value === 'object') {
      assert.equal(value.other, key, `English plural key: ${key}`);
      assert.ok(translated && typeof translated === 'object' && !Array.isArray(translated), `Norwegian plural: ${key}`);
      assert.deepEqual(Object.keys(translated).sort(), Object.keys(value).sort(), `plural forms: ${key}`);
      for (const [form, text] of Object.entries(translated)) {
        assert.ok(typeof text === 'string' && text.trim() !== '', `empty plural form ${form}: ${key}`);
        assert.deepEqual(tokens(text), tokens(value.other), `placeholders of ${form}: ${key}`);
      }
      continue;
    }
    assert.equal(value, key, `English source key: ${key}`);
    assert.ok(typeof translated === 'string' && translated.trim() !== '', `empty Norwegian entry: ${key}`);
    assert.deepEqual(tokens(translated), tokens(value), `placeholders: ${key}`);
  }
});

test('every settings label, unit and option has a catalog entry', () => {
  for (const field of [...Preferences.centerFields, ...Preferences.popupFields]) {
    const texts = [field.label];
    if (field.unit) texts.push(field.unit);
    for (const option of field.options || []) texts.push(Preferences.optionLabel(option));
    for (const text of texts) {
      assert.ok(Object.hasOwn(I.en, text), `${field.key}: "${text}" is not in en.json`);
      assert.ok(Object.hasOwn(I.no, text), `${field.key}: "${text}" is not in no.json`);
    }
  }
});

test('a key that names an Object member is looked up as text, not as the member', () => {
  assert.equal(I.text('constructor', 'no'), 'constructor');
});

assert.equal(manifest.barWidget?.defaults?.language, undefined);
assert.equal((manifest.barWidget?.schema || []).some(f => f.key === 'language'), false);

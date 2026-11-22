const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const I = require('./i18n.cjs');
const Preferences = require('../Preferences.js');
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

test('every error the panel shows from the service or a text field has a catalog entry', () => {
  // The panel's error line passes these through FoamyI18n.t, so each one needs
  // an entry or a Norwegian panel shows English. Each assignment line's
  // literals; only those with a space are texts, which skips "busy".
  const read = file => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
  const errors = new Map();
  const scan = (file, assignment) => {
    for (const line of read(file).split('\n').filter(line => assignment.test(line))) {
      for (const match of line.matchAll(/"((?:[^"\\]|\\.)*)"/g)) if (match[1].includes(' ')) errors.set(match[1], file);
    }
  };
  scan('Service.qml', /\b(focus|load|removal|dnd|snooze)Error = |\blistFailed\("/);
  const service = errors.size;
  assert.ok(service >= 12, `found only ${service} service errors`);
  // The search field's paste errors (kit SafeTextField), shown on the same line.
  scan('kit/SafeTextField.qml', /\bpasteError = /);
  assert.ok(errors.size >= service + 3, `found only ${errors.size - service} paste errors`);
  // The watcher's fixed messages: Service.qml shows a failed stream's error as it is.
  const before = errors.size;
  scan('native/src/watch.rs', /\b(fail|die)\("/);
  const sync = read('native/src/main.rs').split('\npub fn sync(')[1].split('\n}\n')[0];
  for (const match of sync.matchAll(/"((?:[^"\\]|\\.)*)"/g)) errors.set(match[1], 'native/src/main.rs');
  // The watcher first creates the store; its standard-error line is not shown.
  const ensure = read('native/src/store.rs').split('\n    pub fn ensure(')[1].split('\n    }\n')[0];
  for (const line of ensure.split('\n').filter(line => !line.trim().startsWith('//') && !line.includes('eprintln!')))
    for (const match of line.matchAll(/"((?:[^"\\]|\\.)*)"/g)) if (match[1].includes(' ')) errors.set(match[1], 'native/src/store.rs');
  assert.ok(errors.size >= before + 9, `found only ${errors.size - before} watcher errors`);
  for (const [error, file] of errors) {
    assert.ok(Object.hasOwn(I.en, error), `${file}: "${error}" is not in en.json`);
    assert.ok(Object.hasOwn(I.no, error), `${file}: "${error}" is not in no.json`);
  }
});

test('every text a kit field asks the plugin catalog for has an entry', () => {
  // SafeTextField's context menu and FoamyNumberField's range error go
  // through the plugin's translator; comment lines only show usage.
  const texts = new Map();
  for (const file of ['kit/SafeTextField.qml', 'kit/FoamyNumberField.qml']) {
    const lines = fs.readFileSync(path.join(__dirname, '..', file), 'utf8').split('\n').filter(line => !line.trim().startsWith('//'));
    for (const line of lines) for (const match of line.matchAll(/\b(?:translate|FoamyI18n\.t)\("((?:[^"\\]|\\.)*)"/g)) texts.set(match[1], file);
  }
  assert.ok(texts.size >= 7, `found only ${texts.size} texts`);
  for (const [text, file] of texts) {
    assert.ok(Object.hasOwn(I.en, text), `${file}: "${text}" is not in en.json`);
    assert.ok(Object.hasOwn(I.no, text), `${file}: "${text}" is not in no.json`);
  }
});

test('every catalog entry is a text the plugin, its kit copy or its manifest names', () => {
  // A key no source names as a string literal is never shown: drop it from
  // the catalogs. Keys are looked up literally, never built from parts.
  const root = path.join(__dirname, '..');
  // The helper's watcher, sync and store errors reach the panel's error line too.
  const files = ['manifest.json', 'native/src/watch.rs', 'native/src/main.rs', 'native/src/store.rs'];
  for (const dir of ['.', 'components', 'kit']) {
    for (const name of fs.readdirSync(path.join(root, dir))) if (/\.(qml|js)$/.test(name)) files.push(path.join(dir, name));
  }
  // A key that only a comment line names is not shown either.
  const code = file => fs.readFileSync(path.join(root, file), 'utf8').split('\n').filter(line => !line.trim().startsWith('//'));
  const source = files.flatMap(code).join('\n');
  assert.ok(files.length >= 30, `read only ${files.length} files`);
  const unused = Object.keys(I.en).filter(key => !source.includes(JSON.stringify(key)) && !source.includes(`'${key}'`));
  assert.deepEqual(unused, [], 'catalog entries no source uses');
});

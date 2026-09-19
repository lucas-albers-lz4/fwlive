'use strict';

/**
 * i18n smoke test — verifies that every msgid in the POT template has a
 * non-empty msgstr in each available .po file, that format specifiers (%s,
 * %d, etc.) are preserved, and that PO syntax basics are sound.
 *
 * Usage:
 *   node tests/fwlive-i18n.test.js
 *
 * This reads POT + PO files from the openwrt-feed package directory and
 * reports issues. Exits non-zero on any failure.
 *
 * In a full OpenWrt build this is redundant (luci.mk already validates PO
 * syntax at build time), but as a CI gate it catches incomplete translations
 * and format-string corruption before a release.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const PKG_DIR = path.resolve(__dirname, '..', 'openwrt-feed', 'luci-app-fwlive');
const PO_DIR = path.join(PKG_DIR, 'po');
const POT_FILE = path.join(PO_DIR, 'templates', 'luci-app-fwlive.pot');

const RE_FORMAT = /%[%\d.\-+#]*[sdf]/g;

/**
 * Parse a .po/.pot file into an array of { msgid, msgstr, fuzzy } entries.
 * Returns msgstr = null for empty/untranslated entries.
 */
function parsePoFile(filePath) {
  const text = fs.readFileSync(filePath, 'utf8');
  const lines = text.split('\n');
  const entries = [];
  let current = null;
  let onMsgstr = false;
  let pendingFuzzy = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (/^#,.*\bfuzzy\b/.test(line)) {
      pendingFuzzy = true;
      continue;
    }

    // Detect start of new entry (top-level msgid)
    const midMatch = line.match(/^msgid "((?:[^"\\]|\\.)*)"/);
    if (midMatch) {
      if (current && !(current.msgid === '' && current.msgstr === null)) {
        entries.push({
          msgid: current.msgid,
          msgstr: current.msgstr || null,
          fuzzy: current.fuzzy
        });
      }
      current = { msgid: midMatch[1], msgstr: null, fuzzy: pendingFuzzy };
      pendingFuzzy = false;
      onMsgstr = false;
      continue;
    }

    // msgid continuation
    if (!onMsgstr && current && /^"/.test(line)) {
      const inner = line.replace(/^"((?:[^"\\]|\\.)*)"$/, '$1');
      current.msgid += inner;
      continue;
    }

    // msgstr
    const msMatch = line.match(/^msgstr "((?:[^"\\]|\\.)*)"/);
    if (msMatch && current) {
      current.msgstr = msMatch[1];
      onMsgstr = true;
      continue;
    }

    // msgstr continuation
    if (onMsgstr && current && /^"/.test(line)) {
      const inner = line.replace(/^"((?:[^"\\]|\\.)*)"$/, '$1');
      current.msgstr = (current.msgstr || '') + inner;
    }
  }

  // Flush last entry
  if (current && !(current.msgid === '' && current.msgstr === null))
    entries.push({
      msgid: current.msgid,
      msgstr: current.msgstr || null,
      fuzzy: current.fuzzy
    });

  return entries;
}

/**
 * Extract format specifiers from a string. Returns sorted array.
 */
function extractFormats(str) {
  if (!str) return [];
  return (str.match(RE_FORMAT) || []).sort();
}

function translationStatus(entry) {
  if (!entry) return 'missing';
  if (entry.fuzzy) return 'fuzzy';
  if (!entry.msgstr) return 'empty';
  return 'ok';
}

function testFuzzyParser() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-i18n-'));
  const file = path.join(dir, 'fuzzy.po');
  try {
    fs.writeFileSync(
      file,
      [
        '#, fuzzy',
        'msgid "Hello"',
        'msgstr "Bonjour"',
        '',
        'msgid "World"',
        'msgstr "Monde"',
        ''
      ].join('\n')
    );
    const entries = parsePoFile(file);
    if (translationStatus(entries[0]) !== 'fuzzy')
      throw new Error('fuzzy PO entries must be rejected as active translations');
    if (translationStatus(entries[1]) !== 'ok')
      throw new Error('fuzzy state must not leak to the next PO entry');

    const result = inspectCatalog(
      'fixture',
      file,
      ['Hello', 'World'],
      { Hello: [], World: [] },
      false
    );
    if (result.failure !== 1 || result.fuzzy !== 1)
      throw new Error('fuzzy catalog entries must contribute to the gate failure status');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function inspectCatalog(lang, poFile, potIds, potFormats, report = true) {
  if (!fs.existsSync(poFile))
    return { failure: 1, missingFile: true, poEntries: [] };

  const poEntries = parsePoFile(poFile);
  const poMap = {};
  for (const e of poEntries)
    poMap[e.msgid] = e;

  let missing = 0;
  let empty = 0;
  let formatMismatch = 0;
  let mismatched = 0;
  let fuzzy = 0;

  for (const msgid of potIds) {
    const entry = poMap[msgid];
    const status = translationStatus(entry);
    if (status === 'missing') {
      missing++;
      continue;
    }
    if (status === 'fuzzy') {
      fuzzy++;
      continue;
    }
    if (status === 'empty') {
      empty++;
      continue;
    }

    // Format specifier cross-check
    const idFormats = potFormats[msgid] || [];
    const strFormats = extractFormats(entry.msgstr);
    if (JSON.stringify(idFormats) !== JSON.stringify(strFormats)) {
      formatMismatch++;
      if (report && formatMismatch <= 3)
        console.error('[FAIL] %s: format specifier mismatch for "%s" | msgid: %s | msgstr: %s',
          lang, msgid, idFormats.join(' '), strFormats.join(' '));
    }
  }

  // Stale entries
  const poIds = poEntries.map(e => e.msgid);
  for (const msgid of poIds) {
    if (msgid === '') continue;
    if (potIds.indexOf(msgid) === -1) {
      mismatched++;
      if (report && mismatched <= 3)
        console.warn('[WARN] %s: stale msgid (not in POT) "%s"', lang, msgid);
    }
  }

  const total = missing + empty + formatMismatch + fuzzy;
  return {
    failure: total > 0 ? 1 : 0,
    missing,
    empty,
    formatMismatch,
    mismatched,
    fuzzy,
    total,
    poEntries
  };
}

function main() {
  let failures = 0;

  if (!fs.existsSync(POT_FILE)) {
    console.error('POT file not found:', POT_FILE);
    process.exit(1);
  }

  testFuzzyParser();
  const potEntries = parsePoFile(POT_FILE);
  const potIds = potEntries.map(e => e.msgid).filter(id => id !== '');
  console.log('POT: %d translatable msgids (%s)\n', potIds.length, POT_FILE);

  // Build POT format-spec reference map
  const potFormats = {};
  for (const e of potEntries) {
    if (e.msgid) potFormats[e.msgid] = extractFormats(e.msgid);
  }

  // Find all language directories
  const langs = fs.readdirSync(PO_DIR).filter(d =>
    d !== 'templates' && fs.statSync(path.join(PO_DIR, d)).isDirectory()
  );

  if (langs.length === 0) {
    console.log('No translation directories found — nothing to check.');
    return 0;
  }

  for (const lang of langs) {
    const poFile = path.join(PO_DIR, lang, 'luci-app-fwlive.po');
    const result = inspectCatalog(lang, poFile, potIds, potFormats);
    if (result.missingFile) {
      console.error('[FAIL] %s: missing .po file at %s', lang, poFile);
      failures += result.failure;
      continue;
    }

    if (result.total + result.mismatched === 0)
      console.log('[PASS] %s: %d msgids OK, %d entries total — formats verified ✓', lang, potIds.length, result.poEntries.length);
    else {
      if (result.missing) console.error('[FAIL] %s: %d missing msgid(s)', lang, result.missing);
      if (result.empty) console.error('[FAIL] %s: %d empty translation(s)', lang, result.empty);
      if (result.formatMismatch) console.error('[FAIL] %s: %d format specifier mismatch(es)', lang, result.formatMismatch);
      if (result.fuzzy) console.error('[FAIL] %s: %d fuzzy translation(s)', lang, result.fuzzy);
      failures += result.failure;
      if (result.mismatched)
        console.warn('       (%d stale entries — should be cleaned up)', result.mismatched);
    }
  }

  if (failures) {
    console.error('\n%d language(s) have issues.', failures);
    process.exit(1);
  }

  console.log('\nAll %d language(s) pass.', langs.length);
}

main();

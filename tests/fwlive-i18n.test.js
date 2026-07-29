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
const path = require('node:path');

const PKG_DIR = path.resolve(__dirname, '..', 'openwrt-feed', 'luci-app-fwlive');
const PO_DIR = path.join(PKG_DIR, 'po');
const POT_FILE = path.join(PO_DIR, 'templates', 'luci-app-fwlive.pot');

const RE_FORMAT = /%[%\d.\-+#]*[sdf]/g;

/**
 * Parse a .po/.pot file into an array of { msgid, msgstr } entries.
 * Returns msgstr = null for empty/untranslated entries.
 */
function parsePoFile(filePath) {
  const text = fs.readFileSync(filePath, 'utf8');
  const lines = text.split('\n');
  const entries = [];
  let current = null;
  let onMsgstr = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // Detect start of new entry (top-level msgid)
    const midMatch = line.match(/^msgid "((?:[^"\\]|\\.)*)"/);
    if (midMatch) {
      if (current && !(current.msgid === '' && current.msgstr === null)) {
        entries.push({ msgid: current.msgid, msgstr: current.msgstr || null });
      }
      current = { msgid: midMatch[1], msgstr: null };
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
    entries.push({ msgid: current.msgid, msgstr: current.msgstr || null });

  return entries;
}

/**
 * Extract format specifiers from a string. Returns sorted array.
 */
function extractFormats(str) {
  if (!str) return [];
  return (str.match(RE_FORMAT) || []).sort();
}

function main() {
  let failures = 0;

  if (!fs.existsSync(POT_FILE)) {
    console.error('POT file not found:', POT_FILE);
    process.exit(1);
  }

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
    if (!fs.existsSync(poFile)) {
      console.error('[FAIL] %s: missing .po file at %s', lang, poFile);
      failures++;
      continue;
    }

    const poEntries = parsePoFile(poFile);
    const poMap = {};
    for (const e of poEntries)
      poMap[e.msgid] = e;

    let missing = 0;
    let empty = 0;
    let formatMismatch = 0;
    let mismatched = 0;

    for (const msgid of potIds) {
      if (!poMap[msgid]) {
        missing++;
        continue;
      }
      const entry = poMap[msgid];
      if (!entry.msgstr) {
        empty++;
        continue;
      }

      // Format specifier cross-check
      const idFormats = potFormats[msgid] || [];
      const strFormats = extractFormats(entry.msgstr);
      if (JSON.stringify(idFormats) !== JSON.stringify(strFormats)) {
        formatMismatch++;
        if (formatMismatch <= 3)
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
        if (mismatched <= 3)
          console.warn('[WARN] %s: stale msgid (not in POT) "%s"', lang, msgid);
      }
    }

    const total = missing + empty + formatMismatch;
    if (total + mismatched === 0)
      console.log('[PASS] %s: %d msgids OK, %d entries total — formats verified ✓', lang, potIds.length, poEntries.length);
    else {
      if (missing) console.error('[FAIL] %s: %d missing msgid(s)', lang, missing);
      if (empty) console.error('[FAIL] %s: %d empty translation(s)', lang, empty);
      if (formatMismatch) console.error('[FAIL] %s: %d format specifier mismatch(es)', lang, formatMismatch);
      if (missing + empty + formatMismatch > 0) failures++;
      if (mismatched)
        console.warn('       (%d stale entries — should be cleaned up)', mismatched);
    }
  }

  if (failures) {
    console.error('\n%d language(s) have issues.', failures);
    process.exit(1);
  }

  console.log('\nAll %d language(s) pass.', langs.length);
}

main();

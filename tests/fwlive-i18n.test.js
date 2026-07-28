'use strict';

/**
 * i18n smoke test — verifies that every msgid in the POT template has a
 * non-empty msgstr in each available .po file.
 *
 * Usage:
 *   node tests/fwlive-i18n.test.js
 *
 * This reads POT + PO files from the openwrt-feed package directory and
 * reports missing/empty translations. Exits non-zero on any failure.
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

/**
 * Parse a .po/.pot file into an array of { msgid, msgstr } entries.
 * Returns msgstr = null for empty/untranslated entries.
 */
function parsePoFile(filePath) {
  const text = fs.readFileSync(filePath, 'utf8');
  const lines = text.split('\n');
  const entries = [];
  let current = null;
  let onMsgstr = false; // set after msgid line; cleared when next entry starts

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

    // msgid continuation (next line after msgid "..."
    if (!onMsgstr && current && /^"/.test(line)) {
      const inner = line.replace(/^"((?:[^"\\]|\\.)*)"$/, '$1');
      current.msgid += inner;
      continue;
    }

    // msgstr
    const msMatch = line.match(/^msgstr "((?:[^"\\]|\\.)*)"/);
    if (msMatch && current) {
      current.msgstr = msMatch[1]; // may be empty string ""
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

function main() {
  let failures = 0;

  if (!fs.existsSync(POT_FILE)) {
    console.error('POT file not found:', POT_FILE);
    process.exit(1);
  }

  const potEntries = parsePoFile(POT_FILE);
  const potIds = potEntries.map(e => e.msgid).filter(id => id !== '');
  console.log('POT: %d translatable msgids (%s)', potIds.length, POT_FILE);

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
    let mismatched = 0;

    for (const msgid of potIds) {
      if (!poMap[msgid]) {
        missing++;
        if (missing <= 5)
          console.error('[FAIL] %s: missing msgid "%s"', lang, msgid);
        continue;
      }
      if (!poMap[msgid].msgstr) {
        empty++;
        if (empty <= 5)
          console.error('[FAIL] %s: empty translation for "%s"', lang, msgid);
      }
    }

    // Check for stale entries in PO (not in POT anymore)
    const poIds = poEntries.map(e => e.msgid);
    for (const msgid of poIds) {
      if (msgid === '') continue; // header is special
      if (potIds.indexOf(msgid) === -1) {
        mismatched++;
        if (mismatched <= 3)
          console.warn('[WARN] %s: stale msgid (not in POT) "%s"', lang, msgid);
      }
    }

    if (missing + empty + mismatched === 0)
      console.log('[PASS] %s: %d/msgids translated, %d total', lang, potIds.length, poEntries.length);
    else {
      if (missing + empty > 0) {
        failures++;
        if (missing > 5) console.error('       ... and %d more missing', missing - 5);
        if (empty > 5) console.error('       ... and %d more empty', empty - 5);
      }
      if (mismatched) 
        console.warn('       (%d stale entries in PO — should be cleaned up)', mismatched);
    }
  }

  if (failures) {
    console.error('\n%d language(s) have issues.', failures);
    process.exit(1);
  }

  console.log('\nAll %d language(s) pass.', langs.length);
}

main();

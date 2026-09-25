'use strict';

/**
 * Source-to-POT drift gate (#334 / #454).
 *
 * The OpenWrt i18n scanner is not available in the normal host checkout, so
 * this gate checks the static string-literal form of every _() call in the
 * shipped JavaScript sources, including template-literal interpolations,
 * against the checked-in POT. It also requires each `#:` reference's cited
 * line to contain that msgid as a quoted string, and requires JS `#:` refs to
 * occupy extracted `_()` occurrences rather than merely resolving on a
 * containing line. Nearby `_()` calls must not satisfy resolvability. It
 * intentionally does not claim coverage for dynamic or concatenated
 * translation arguments.
 *
 * Usage:
 *   node tests/fwlive-i18n-source.test.js
 */

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const RESOURCE_DIR = path.join(
	ROOT,
	'openwrt-feed',
	'luci-app-fwlive',
	'htdocs',
	'luci-static',
	'resources'
);
const POT_FILE = path.join(
	ROOT,
	'openwrt-feed',
	'luci-app-fwlive',
	'po',
	'templates',
	'luci-app-fwlive.pot'
);

const REGRESSION_MSGIDS = [
	'Degraded — sampling',
	'resolve paused (load)',
	'Degraded — sampling (slow poll RTT; cadence reduced).',
	'Server shedding — at most %d log lines per poll.',
	'Server truncated this poll (adaptive cap).',
	'Hostname resolve paused while the router is under load.',
	/* Chip format/connector (#511): the scanner only sees existing _() literals. */
	'%s: %s',
	'does not contain'
];

function isIdentifierStart(ch) {
	return !!ch && /[A-Za-z_$]/.test(ch);
}

function isIdentifierPart(ch) {
	return !!ch && /[A-Za-z0-9_$]/.test(ch);
}

function isHex(ch) {
	return !!ch && /[0-9A-Fa-f]/.test(ch);
}

function decodeEscapedText(raw) {
	let out = '';
	for (let i = 0; i < raw.length; i++) {
		const ch = raw[i];
		if (ch !== '\\') {
			out += ch;
			continue;
		}

		if (i + 1 >= raw.length) {
			out += '\\';
			continue;
		}

		const next = raw[++i];
		if (next === '\n') continue;
		if (next === '\r') {
			if (raw[i + 1] === '\n') i++;
			continue;
		}

		const simple = {
			b: '\b',
			f: '\f',
			n: '\n',
			r: '\r',
			t: '\t',
			v: '\v',
			'0': '\0'
		};
		if (Object.prototype.hasOwnProperty.call(simple, next)) {
			out += simple[next];
			continue;
		}
		if (next === 'x' && isHex(raw[i + 1]) && isHex(raw[i + 2])) {
			out += String.fromCharCode(parseInt(raw.slice(i + 1, i + 3), 16));
			i += 2;
			continue;
		}
		if (next === 'u') {
			if (raw[i + 1] === '{') {
				const end = raw.indexOf('}', i + 2);
				const hex = end >= 0 ? raw.slice(i + 2, end) : '';
				if (hex && /^[0-9A-Fa-f]+$/.test(hex)) {
					out += String.fromCodePoint(parseInt(hex, 16));
					i = end;
					continue;
				}
			} else {
				const hex = raw.slice(i + 1, i + 5);
				if (hex.length === 4 && [...hex].every(isHex)) {
					out += String.fromCharCode(parseInt(hex, 16));
					i += 4;
					continue;
				}
			}
		}

		/* JavaScript identity escapes preserve the escaped character here. */
		out += next;
	}
	return out;
}

function readQuotedString(source, start, limit = source.length) {
	const quote = source[start];
	let raw = '';
	for (let i = start + 1; i < limit; i++) {
		const ch = source[i];
		if (ch === quote) return { value: decodeEscapedText(raw), end: i + 1 };
		if (ch === '\\' && i + 1 < limit) raw += ch + source[++i];
		else raw += ch;
	}
	return null;
}

function skipLineComment(source, start) {
	const end = source.indexOf('\n', start + 2);
	return end < 0 ? source.length : end;
}

function skipBlockComment(source, start) {
	const end = source.indexOf('*/', start + 2);
	return end < 0 ? source.length : end + 2;
}

function skipTemplate(source, start) {
	for (let i = start + 1; i < source.length; i++) {
		if (source[i] === '\\') {
			i++;
			continue;
		}
		if (source[i] === '`') return i + 1;
	}
	return source.length;
}

function findTemplateExpressionEnd(source, start, limit = source.length) {
	let depth = 1;
	for (let i = start; i < limit; i++) {
		const ch = source[i];
		if (ch === '\\') {
			i++;
			continue;
		}
		if (ch === "'" || ch === '"') {
			const string = readQuotedString(source, i, limit);
			i = string ? string.end - 1 : limit;
			continue;
		}
		if (ch === '`') {
			i = skipTemplate(source, i) - 1;
			continue;
		}
		if (ch === '/' && source[i + 1] === '/') {
			i = skipLineComment(source, i);
			continue;
		}
		if (ch === '/' && source[i + 1] === '*') {
			i = skipBlockComment(source, i) - 1;
			continue;
		}
		if (ch === '{') depth++;
		else if (ch === '}' && --depth === 0) return i;
	}
	return limit;
}

function scanTemplateExpressions(source, start, filePath, found) {
	for (let i = start + 1; i < source.length; i++) {
		if (source[i] === '\\') {
			i++;
			continue;
		}
		if (source[i] === '`') return i + 1;
		if (source[i] === '$' && source[i + 1] === '{') {
			const expressionStart = i + 2;
			const expressionEnd = findTemplateExpressionEnd(source, expressionStart);
			found.push(...extractI18nLiterals(source, filePath, expressionStart, expressionEnd));
			i = expressionEnd;
		}
	}
	return source.length;
}

function skipRegex(source, start) {
	let inClass = false;
	for (let i = start + 1; i < source.length; i++) {
		if (source[i] === '\\') {
			i++;
			continue;
		}
		if (source[i] === '[') inClass = true;
		else if (source[i] === ']') inClass = false;
		else if (source[i] === '/' && !inClass) {
			i++;
			while (/[A-Za-z]/.test(source[i] || '')) i++;
			return i;
		} else if (source[i] === '\n' || source[i] === '\r') return start + 1;
	}
	return source.length;
}

function skipSpaceAndComments(source, start) {
	let i = start;
	while (i < source.length) {
		if (/\s/.test(source[i])) {
			i++;
			continue;
		}
		if (source[i] === '/' && source[i + 1] === '/') {
			i = skipLineComment(source, i);
			continue;
		}
		if (source[i] === '/' && source[i + 1] === '*') {
			i = skipBlockComment(source, i);
			continue;
		}
		break;
	}
	return i;
}

const REGEX_PREFIX_KEYWORDS = new Set([
	'return',
	'throw',
	'case',
	'delete',
	'void',
	'typeof',
	'instanceof',
	'in',
	'of',
	'yield',
	'await',
	'else',
	'do',
	'new'
]);

function canStartRegex(previousSignificant, previousWasProperty) {
	if (previousWasProperty) return false;
	return (
		!previousSignificant ||
		REGEX_PREFIX_KEYWORDS.has(previousSignificant) ||
		/[([{=,:;!?&|+\-*%^~<>]/.test(previousSignificant)
	);
}

function lineNumber(source, offset) {
	return source.slice(0, offset).split('\n').length;
}

function normalizeSourceMsgid(value) {
	/* xgettext trims whitespace at the edges of a translatable fragment. */
	return value.trim();
}

function extractI18nLiterals(source, filePath, start = 0, end = source.length) {
	const found = [];
	let previousSignificant = '';
	let previousWasProperty = false;

	for (let i = start; i < end;) {
		const ch = source[i];
		if (/\s/.test(ch)) {
			i++;
			continue;
		}
		if (ch === '/' && source[i + 1] === '/') {
			i = skipLineComment(source, i);
			continue;
		}
		if (ch === '/' && source[i + 1] === '*') {
			i = skipBlockComment(source, i);
			continue;
		}
		if (ch === "'" || ch === '"') {
			const string = readQuotedString(source, i, end);
			i = string ? string.end : source.length;
			previousSignificant = 'value';
			previousWasProperty = false;
			continue;
		}
		if (ch === '`') {
			i = scanTemplateExpressions(source, i, filePath, found);
			previousSignificant = 'value';
			previousWasProperty = false;
			continue;
		}
		if (ch === '/' && canStartRegex(previousSignificant, previousWasProperty)) {
			i = skipRegex(source, i);
			previousSignificant = 'value';
			previousWasProperty = false;
			continue;
		}

		if (isIdentifierStart(ch)) {
			const start = i;
			const isProperty = previousSignificant === '.';
			i++;
			while (isIdentifierPart(source[i])) i++;
			const identifier = source.slice(start, i);
			if (identifier === '_') {
				const open = skipSpaceAndComments(source, i);
				const arg = skipSpaceAndComments(source, open + 1);
				if (source[open] === '(' && (source[arg] === "'" || source[arg] === '"')) {
					const string = readQuotedString(source, arg, end);
					if (string) {
						found.push({
							msgid: normalizeSourceMsgid(string.value),
							file: filePath,
							line: lineNumber(source, start),
							msgidLine: lineNumber(source, arg)
						});
					}
				}
			}
			previousSignificant = identifier;
			previousWasProperty = isProperty;
			continue;
		}

		previousSignificant = ch;
		previousWasProperty = false;
		i++;
	}
	return found;
}

function javascriptFiles(dir) {
	const files = [];
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) files.push(...javascriptFiles(full));
		else if (entry.isFile() && entry.name.endsWith('.js')) files.push(full);
	}
	return files.sort();
}

function extractSourceMessages() {
	const messages = [];
	for (const file of javascriptFiles(RESOURCE_DIR)) {
		const relative = path.relative(ROOT, file);
		messages.push(...extractI18nLiterals(fs.readFileSync(file, 'utf8'), relative));
	}
	return messages;
}

function parsePoQuoted(raw) {
	return decodeEscapedText(raw);
}

/*
 * This gate compares msgid catalogs and verifies each POT #: reference
 * resolves to a line containing that msgid. The shipped sources do not emit
 * ngettext/msgctxt entries; extend this parser if that changes.
 */
function parsePotMsgids(text) {
	const ids = new Set();
	for (const entry of parsePotEntries(text)) {
		if (entry.msgid !== '') ids.add(entry.msgid);
	}
	return ids;
}

function parsePotEntries(text) {
	const entries = [];
	for (const block of text.split(/\n{2,}/)) {
		if (!block.trim()) continue;

		const refs = [];
		let msgid = null;
		let readingId = false;
		for (const line of block.split('\n')) {
			const refMatch = line.match(/^#:\s*(.+)$/);
			if (refMatch) {
				for (const part of refMatch[1].trim().split(/\s+/)) {
					const match = part.match(/^(.+):(\d+)$/);
					if (match) {
						refs.push({ file: match[1], line: parseInt(match[2], 10) });
					} else {
						refs.push({ file: part, line: 0 });
					}
				}
				continue;
			}

			const idMatch = line.match(/^msgid "((?:[^"\\]|\\.)*)"$/);
			if (idMatch) {
				msgid = parsePoQuoted(idMatch[1]);
				readingId = true;
				continue;
			}
			if (readingId && msgid !== null && /^"((?:[^"\\]|\\.)*)"$/.test(line)) {
				msgid += parsePoQuoted(line.slice(1, -1));
				continue;
			}
			if (/^msgstr(?:\[.*\])? /.test(line) || line === '') readingId = false;
		}
		if (msgid !== null) entries.push({ msgid, refs });
	}
	return entries;
}

function escapeJsString(value, quote) {
	return value
		.replace(/\\/g, '\\\\')
		.replace(/\n/g, '\\n')
		.replace(/\r/g, '\\r')
		.replace(quote === "'" ? /'/g : /"/g, quote === "'" ? "\\'" : '\\"');
}

function escapeRegExp(value) {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function lineContainsMsgid(line, msgid) {
	if (!msgid) return false;
	const single = escapeRegExp(escapeJsString(msgid, "'"));
	const double = escapeRegExp(escapeJsString(msgid, '"'));
	/* xgettext trims edge whitespace; source quotes may keep it. */
	return new RegExp(`'\\s*${single}\\s*'`).test(line) || new RegExp(`"\\s*${double}\\s*"`).test(line);
}

function isUnclosedGettextCall(line) {
	return /_\(\s*$/.test(line);
}

function verifyPotReference(ref, msgid) {
	const fullPath = path.join(ROOT, ref.file);
	if (!fs.existsSync(fullPath)) {
		return { ok: false, reason: 'file not found' };
	}

	const lines = fs.readFileSync(fullPath, 'utf8').split('\n');
	if (ref.line < 1 || ref.line > lines.length) {
		return { ok: false, reason: 'line out of range' };
	}

	const referenceLine = lines[ref.line - 1];
	if (lineContainsMsgid(referenceLine, msgid)) {
		return { ok: true };
	}

	/*
	 * Wrapped `_(\n "msgid")` cites the opening line. Search forward only so a
	 * nearby closed `_('other')` cannot satisfy this msgid.
	 */
	if (!isUnclosedGettextCall(referenceLine) && !msgid.includes('\n')) {
		return { ok: false, reason: 'referenced line does not contain msgid' };
	}

	const end = Math.min(lines.length, ref.line + 7);
	for (let line = ref.line + 1; line <= end; line++) {
		if (lineContainsMsgid(lines[line - 1], msgid)) return { ok: true };
	}
	return { ok: false, reason: 'msgid not found on cited or continuation lines' };
}

function findNearbyUnrelatedGettextLine(ref, msgid) {
	const lines = fs.readFileSync(path.join(ROOT, ref.file), 'utf8').split('\n');
	const start = Math.max(1, ref.line - 5);
	const end = Math.min(lines.length, ref.line + 5);
	for (let line = start; line <= end; line++) {
		if (line === ref.line) continue;
		const text = lines[line - 1];
		if (text.includes('_(') && !lineContainsMsgid(text, msgid)) return line;
	}
	return 0;
}

function checkPotReferences(potText) {
	const mismatches = [];

	for (const entry of parsePotEntries(potText)) {
		if (!entry.msgid) continue;
		for (const ref of entry.refs) {
			const result = verifyPotReference(ref, entry.msgid);
			if (!result.ok) {
				mismatches.push({
					msgid: entry.msgid,
					ref: `${ref.file}:${ref.line}`,
					reason: result.reason
				});
			}
		}
	}

	return mismatches;
}

function occupancyKey(msgid, file) {
	return `${msgid}\0${file}`;
}

function slotAcceptsLine(slot, line) {
	return line === slot.line || line === slot.msgidLine;
}

/*
 * Assumption: 0 same-line duplicate `_()` of one msgid on master. Do not
 * collapse those slots. If i18n-scan.pl ever emits one `#:` for two same-line
 * calls, occupancy would false-red; revisit then.
 */
function checkPotReferenceLocations(sourceMessages, potText) {
	const extras = [];
	const missing = [];
	const slotsByKey = new Map();
	const refsByKey = new Map();

	for (const message of sourceMessages) {
		const key = occupancyKey(message.msgid, message.file);
		if (!slotsByKey.has(key)) slotsByKey.set(key, []);
		slotsByKey.get(key).push(message);
	}

	for (const entry of parsePotEntries(potText)) {
		if (!entry.msgid) continue;
		for (const ref of entry.refs) {
			if (!ref.file.endsWith('.js')) continue;
			const key = occupancyKey(entry.msgid, ref.file);
			if (!refsByKey.has(key)) refsByKey.set(key, []);
			refsByKey.get(key).push(ref);
		}
	}

	const keys = new Set([...slotsByKey.keys(), ...refsByKey.keys()]);
	for (const key of keys) {
		const slots = (slotsByKey.get(key) || []).map((slot) => ({
			file: slot.file,
			line: slot.line,
			msgidLine: slot.msgidLine,
			used: false
		}));
		const refs = refsByKey.get(key) || [];

		for (const ref of refs) {
			const candidates = slots.filter(
				(slot) => !slot.used && slotAcceptsLine(slot, ref.line)
			);
			if (candidates.length > 1) {
				throw new Error('ambiguous slots');
			}
			if (candidates.length === 1) {
				candidates[0].used = true;
				continue;
			}
			extras.push(`${ref.file}:${ref.line}`);
		}

		for (const slot of slots) {
			if (!slot.used) missing.push(`${slot.file}:${slot.msgidLine}`);
		}
	}

	return { extras, missing };
}

function checkSourceToPot(sourceMessages, potText) {
	const sourceIds = new Set(sourceMessages.map((message) => message.msgid));
	const potIds = parsePotMsgids(potText);
	const missing = [...sourceIds].filter((id) => !potIds.has(id)).sort();
	return { sourceIds, potIds, missing };
}

function removePotEntry(potText, msgid) {
	const blocks = potText.split(/\n{2,}/);
	const kept = blocks.filter((block) => !parsePotMsgids(block).has(msgid));
	return kept.join('\n\n');
}

function replacePotReference(potText, msgid, fromRef, toRef) {
	const blocks = potText.split(/\n{2,}/);
	const updated = blocks.map((block) => {
		if (!parsePotMsgids(block).has(msgid)) return block;
		return block.replace(new RegExp(`^#:\\s*${escapeRegExp(fromRef)}\\s*$`, 'm'), `#: ${toRef}`);
	});
	return updated.join('\n\n');
}

function removePotReference(potText, msgid, fileLine) {
	const pattern = new RegExp(`^#:\\s*${escapeRegExp(fileLine)}\\s*$`);
	const blocks = potText.split(/\n{2,}/);
	const updated = blocks.map((block) => {
		if (!parsePotMsgids(block).has(msgid)) return block;
		return block
			.split('\n')
			.filter((line) => !pattern.test(line))
			.join('\n');
	});
	return updated.join('\n\n');
}

function main() {
	if (!fs.existsSync(POT_FILE)) {
		console.error('POT file not found:', POT_FILE);
		return 1;
	}

	const scannerFixture = [
		"function fixture(value) {",
		"\tif (value) return /_('not a message')/;",
		"\telse /_('not after else')/;",
		"\tdo /_('not after do')/; while (value);",
		"\tnew /_('not after new')/;",
		"\tconst division = object.in / _('division message') / 2;",
		"\tconst text = `${_('template message')}`;",
		'}'
	].join('\n');
	const scannerFixtureMessages = extractI18nLiterals(scannerFixture, 'scanner-fixture.js');
	if (
		scannerFixtureMessages.map((message) => message.msgid).sort().join('|') !==
		'division message|template message'
	) {
		console.error('Scanner fixture failed: template interpolation or regex handling changed');
		return 1;
	}

	const sourceMessages = extractSourceMessages();
	const potText = fs.readFileSync(POT_FILE, 'utf8');
	const report = checkSourceToPot(sourceMessages, potText);
	console.log(
		'Source-to-POT: %d unique static _() literals across %d files, %d POT msgids',
		report.sourceIds.size,
		javascriptFiles(RESOURCE_DIR).length,
		report.potIds.size
	);

	if (report.missing.length) {
		console.error('Missing source msgids:');
		for (const id of report.missing) {
			const locations = sourceMessages
				.filter((message) => message.msgid === id)
				.map((message) => `${message.file}:${message.line}`)
				.join(', ');
			console.error(`- ${id} (${locations})`);
		}
		return 1;
	}

	const referenceMismatches = checkPotReferences(potText);
	if (referenceMismatches.length) {
		console.error('Stale POT #: references:');
		for (const mismatch of referenceMismatches) {
			console.error(`- ${mismatch.ref} (${mismatch.reason}) -> ${mismatch.msgid}`);
		}
		return 1;
	}

	let occupancy;
	try {
		occupancy = checkPotReferenceLocations(sourceMessages, potText);
	} catch (err) {
		if (err && err.message === 'ambiguous slots') {
			console.error('POT #: occupancy mismatches: ambiguous slots');
			return 1;
		}
		throw err;
	}
	if (occupancy.extras.length || occupancy.missing.length) {
		console.error('POT #: occupancy mismatches:');
		for (const extra of occupancy.extras) {
			console.error(`- extra ${extra}`);
		}
		for (const miss of occupancy.missing) {
			console.error(`- missing ${miss}`);
		}
		return 1;
	}

	const occupancyMsgid =
		'Another change is staged for the firewall; apply or revert it first.';
	const occupancySlotsByFile = new Map();
	for (const message of sourceMessages) {
		if (message.msgid !== occupancyMsgid) continue;
		if (!occupancySlotsByFile.has(message.file)) occupancySlotsByFile.set(message.file, []);
		occupancySlotsByFile.get(message.file).push(message);
	}
	let occupancyFile = '';
	let occupancyFileSlots = [];
	for (const [file, slots] of occupancySlotsByFile) {
		const ordered = slots.slice().sort((a, b) => a.line - b.line);
		if (ordered.length >= 2 && ordered[0].line !== ordered[0].msgidLine) {
			occupancyFile = file;
			occupancyFileSlots = ordered;
			break;
		}
	}
	if (!occupancyFile) {
		console.error(
			'Occupancy mutation fixture missing: expected one file with ≥2 slots and a wrapped first slot'
		);
		return 1;
	}
	const firstSlot = occupancyFileSlots[0];
	const secondSlot = occupancyFileSlots[1];
	const firstTokenRef = `${occupancyFile}:${firstSlot.line}`;
	const firstMsgidRef = `${occupancyFile}:${firstSlot.msgidLine}`;
	const secondTokenRef = `${occupancyFile}:${secondSlot.line}`;
	const secondMsgidRef = `${occupancyFile}:${secondSlot.msgidLine}`;

	const occupancyResolvable = (mutated, label) => {
		if (checkPotReferences(mutated).length) {
			console.error(`Occupancy ${label} mutation failed resolvability`);
			return false;
		}
		return true;
	};
	const occupancyKind = (mutated) => checkPotReferenceLocations(sourceMessages, mutated);

	const insertedPot = replacePotReference(
		potText,
		occupancyMsgid,
		firstTokenRef,
		`${firstTokenRef}\n#: ${firstTokenRef}`
	);
	if (insertedPot === potText || !occupancyResolvable(insertedPot, 'insert-duplicate')) return 1;
	const insertedOccupancy = occupancyKind(insertedPot);
	if (
		insertedOccupancy.extras.join('|') !== firstTokenRef ||
		insertedOccupancy.missing.length
	) {
		console.error(
			'Occupancy insert-duplicate mutation did not fail extra-only at the duplicated token line'
		);
		return 1;
	}

	const droppedPot = removePotReference(potText, occupancyMsgid, secondTokenRef);
	if (droppedPot === potText || !occupancyResolvable(droppedPot, 'drop')) return 1;
	const droppedOccupancy = occupancyKind(droppedPot);
	if (
		droppedOccupancy.extras.length ||
		droppedOccupancy.missing.join('|') !== secondMsgidRef
	) {
		console.error(
			'Occupancy drop mutation did not fail missing-only at the second slot msgidLine'
		);
		return 1;
	}

	const wrapTwicePot = removePotReference(
		replacePotReference(
			potText,
			occupancyMsgid,
			firstTokenRef,
			`${firstTokenRef}\n#: ${firstMsgidRef}`
		),
		occupancyMsgid,
		secondTokenRef
	);
	if (wrapTwicePot === potText || !occupancyResolvable(wrapTwicePot, 'wrap-twice')) return 1;
	const wrapTwiceOccupancy = occupancyKind(wrapTwicePot);
	if (
		wrapTwiceOccupancy.extras.join('|') !== firstMsgidRef ||
		wrapTwiceOccupancy.missing.join('|') !== secondMsgidRef
	) {
		console.error(
			'Occupancy wrap-twice mutation did not fail extra first msgidLine and missing second msgidLine'
		);
		return 1;
	}

	const wrapPassPot = replacePotReference(
		potText,
		occupancyMsgid,
		firstTokenRef,
		firstMsgidRef
	);
	if (wrapPassPot === potText || !occupancyResolvable(wrapPassPot, 'wrap-pass')) return 1;
	const wrapPassOccupancy = occupancyKind(wrapPassPot);
	if (wrapPassOccupancy.extras.length || wrapPassOccupancy.missing.length) {
		console.error('Occupancy wrap-pass mutation failed after citing the first slot msgidLine');
		return 1;
	}

	const referenceFixtureMsgid = 'does not contain';
	const referenceFixture = parsePotEntries(potText).find(
		(entry) => entry.msgid === referenceFixtureMsgid && entry.refs.length
	);
	if (!referenceFixture) {
		console.error(`Reference fixture msgid is missing from POT: ${referenceFixtureMsgid}`);
		return 1;
	}
	const staleRef = referenceFixture.refs[0];
	const farMutatedPotRefs = replacePotReference(
		potText,
		referenceFixtureMsgid,
		`${staleRef.file}:${staleRef.line}`,
		`${staleRef.file}:1`
	);
	if (farMutatedPotRefs === potText || !checkPotReferences(farMutatedPotRefs).length) {
		console.error('Mutation did not expose stale #: reference drift');
		return 1;
	}

	const nearbyLine = findNearbyUnrelatedGettextLine(staleRef, referenceFixtureMsgid);
	if (!nearbyLine) {
		console.error(`No nearby unrelated _() line to mutate #: ${staleRef.file}:${staleRef.line}`);
		return 1;
	}
	const nearbyMutatedPotRefs = replacePotReference(
		potText,
		referenceFixtureMsgid,
		`${staleRef.file}:${staleRef.line}`,
		`${staleRef.file}:${nearbyLine}`
	);
	if (nearbyMutatedPotRefs === potText || !checkPotReferences(nearbyMutatedPotRefs).length) {
		console.error('Mutation did not expose nearby stale #: reference drift');
		return 1;
	}

	for (const id of REGRESSION_MSGIDS) {
		if (!report.sourceIds.has(id) || !report.potIds.has(id)) {
			console.error(`Regression fixture is not present in source and POT: ${id}`);
			return 1;
		}
		const mutated = checkSourceToPot(sourceMessages, removePotEntry(potText, id));
		if (!mutated.missing.includes(id)) {
			console.error(`Mutation did not expose source drift for: ${id}`);
			return 1;
		}
	}

	console.log(
		'Mutation check: all %d Layer 2 msgids fail when removed from a temporary POT',
		REGRESSION_MSGIDS.length
	);
	console.log('POT #: reference check: all msgid references resolve in tree');
	console.log('POT #: occupancy check: JS refs occupy extracted _() slots');
	console.log('Source-to-POT drift gate passed.');
	return 0;
}

process.exitCode = main();

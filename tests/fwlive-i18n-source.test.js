'use strict';

/**
 * Source-to-POT drift gate (#334).
 *
 * The OpenWrt i18n scanner is not available in the normal host checkout, so
 * this gate checks the static string-literal form of every _() call in the
 * shipped JavaScript sources, including template-literal interpolations,
 * against the checked-in POT. It intentionally does not claim coverage for
 * dynamic or concatenated translation arguments.
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
	'Hostname resolve paused while the router is under load.'
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
							line: lineNumber(source, start)
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
 * This gate currently compares msgid-only catalogs. The shipped sources do
 * not emit ngettext/msgctxt entries; extend this parser if that changes.
 */
function parsePotMsgids(text) {
	const ids = new Set();
	let current = null;
	let readingId = false;
	for (const line of text.split('\n')) {
		const match = line.match(/^msgid "((?:[^"\\]|\\.)*)"$/);
		if (match) {
			if (current !== null && current !== '') ids.add(current);
			current = parsePoQuoted(match[1]);
			readingId = true;
			continue;
		}
		if (readingId && current !== null && /^"((?:[^"\\]|\\.)*)"$/.test(line)) {
			current += parsePoQuoted(line.slice(1, -1));
			continue;
		}
		if (/^msgstr(?:\[.*\])? /.test(line) || line === '') readingId = false;
	}
	if (current !== null && current !== '') ids.add(current);
	return ids;
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
	console.log('Source-to-POT drift gate passed.');
	return 0;
}

process.exitCode = main();

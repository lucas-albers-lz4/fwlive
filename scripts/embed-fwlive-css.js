#!/usr/bin/env node
'use strict';

/**
 * Embed fwlive.css into LuCI css.js (styleText string for E('style', …) injection).
 * Usage:
 *   node scripts/embed-fwlive-css.js
 *   node scripts/embed-fwlive-css.js > openwrt-feed/.../fwlive/css.js
 *
 * Default: write css.js in place. Pass --stdout to print only (freshness tests).
 */

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const CSS_SRC = path.join(
	ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/fwlive.css'
);
const CSS_JS = path.join(
	ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/css.js'
);

function generate(cssText) {
	const body = cssText.endsWith('\n') ? cssText : cssText + '\n';
	/* Leading newline mirrors historical styleText shape for readable diffs. */
	const styleText = '\n' + body;
	return [
		"'use strict';",
		"'require baseclass';",
		'',
		'/**',
		' * Inline stylesheet string for luci-app-fwlive.',
		" * Exports CSS text for E('style', {}, css.styleText) injection — NOT a standalone .css asset.",
		' * LuCI modules must return baseclass.extend(...) — plain objects fail Class.isSubclass.',
		' *',
		' * GENERATED — do not edit. Edit fwlive.css and run: node scripts/embed-fwlive-css.js',
		' */',
		'return baseclass.extend({',
		'\tstyleText: ' + JSON.stringify(styleText),
		'});',
		''
	].join('\n');
}

function main() {
	const cssText = fs.readFileSync(CSS_SRC, 'utf8');
	const out = generate(cssText);
	const stdoutOnly = process.argv.includes('--stdout');
	if (stdoutOnly) {
		process.stdout.write(out);
		return;
	}
	fs.writeFileSync(CSS_JS, out);
	process.stderr.write('wrote ' + path.relative(ROOT, CSS_JS) + '\n');
}

if (require.main === module)
	main();

module.exports = { generate, CSS_SRC, CSS_JS };

'use strict';

/**
 * Flat ESLint config for shipped LuCI JS (#290 / #288 M1).
 * LuCI AMD modules use top-level `return` and `'require …';` strings.
 * We wrap each file in an IIFE for parsing (runtime still loads via LuCI).
 */

const path = require('node:path');
const js = require('@eslint/js');

const luciBrowserGlobals = {
	document: 'readonly',
	window: 'readonly',
	localStorage: 'readonly',
	location: 'readonly',
	setTimeout: 'readonly',
	clearTimeout: 'readonly',
	requestAnimationFrame: 'readonly',
	console: 'readonly',
	URL: 'readonly',
	URLSearchParams: 'readonly',
	JSON: 'readonly',
	Math: 'readonly',
	Date: 'readonly',
	Object: 'readonly',
	Array: 'readonly',
	String: 'readonly',
	Number: 'readonly',
	Boolean: 'readonly',
	Error: 'readonly',
	Promise: 'readonly',
	Map: 'readonly',
	Set: 'readonly',
	parseInt: 'readonly',
	parseFloat: 'readonly',
	isNaN: 'readonly',
	getComputedStyle: 'readonly',
	performance: 'readonly',
	Event: 'readonly',
	encodeURIComponent: 'readonly',
	decodeURIComponent: 'readonly',
};

const luciRuntimeGlobals = {
	L: 'readonly',
	_: 'readonly',
	E: 'readonly',
	baseclass: 'readonly',
	view: 'readonly',
	poll: 'readonly',
	rpc: 'readonly',
	dom: 'readonly',
	ui: 'readonly',
	form: 'readonly',
	fs: 'readonly',
	uci: 'readonly',
	network: 'readonly',
};

const fwliveViewAliases = {
	log: 'readonly',
	constants: 'readonly',
	css: 'readonly',
	tint: 'readonly',
	chips: 'readonly',
	logging: 'readonly',
	table: 'readonly',
	buffer: 'readonly',
	hostname: 'readonly',
	proto: 'readonly',
	links: 'readonly',
	renderPolicy: 'readonly',
	pollCoordinator: 'readonly',
	renderScheduler: 'readonly',
};

/** Wrap LuCI AMD bodies so top-level `return` parses under Espree. */
const luciAmdWrap = {
	preprocess(text, filename) {
		const name = path.basename(filename);
		return [
			{
				text: '(function () {\n' + text + '\n})();\n',
				filename: name + '.wrapped',
			},
		];
	},
	postprocess(messages) {
		/* Drop the synthetic wrapper file name; shift lines by -1 for the wrap. */
		return messages.flat().map((msg) => {
			if (typeof msg.line === 'number' && msg.line > 1)
				return { ...msg, line: msg.line - 1 };
			return msg;
		});
	},
	supportsAutofix: false,
};

/* Shipped LuCI AMD modules share one file set, one language environment and one
 * rule set. They are attached to TWO filenames on purpose: the processor below
 * rewrites each file into a virtual `<name>.js.wrapped` file before linting, and
 * flat config applies configuration per FILENAME — so rules attached only to
 * `*.js` never reach the processed text. */
const shippedJsFiles = [
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/**/*.js',
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js',
];

const shippedJsLanguageOptions = {
	ecmaVersion: 2020,
	sourceType: 'script',
	globals: {
		...luciBrowserGlobals,
		...luciRuntimeGlobals,
		...fwliveViewAliases,
	},
};

const shippedJsRules = {
	...js.configs.recommended.rules,
	'no-undef': 'error',
	'no-implicit-globals': 'error',
	'no-eval': 'error',
	'no-unused-vars': [
		'error',
		{
			argsIgnorePattern: '^_',
			varsIgnorePattern: '^_',
			caughtErrorsIgnorePattern: '^_',
		},
	],
	/* LuCI AMD: `'require foo';` is an intentional unused expression. */
	'no-unused-expressions': 'off',
	indent: 'off',
	semi: ['error', 'always'],
	'no-var': 'off',
};

module.exports = [
	{
		ignores: [
			'out/**',
			'build/**',
			'node_modules/**',
			'lab/**',
			'wave/**',
			'coverage/**',
			'openwrt/**',
			'.sdk/**',
			'.ci-sdk-cache/**',
			'core/**',
			'tests/**',
			'scripts/**',
		],
	},
	{
		files: shippedJsFiles,
		plugins: {
			'luci-amd-wrap': {
				processors: {
					wrap: luciAmdWrap,
				},
			},
		},
		processor: 'luci-amd-wrap/wrap',
		languageOptions: shippedJsLanguageOptions,
		rules: shippedJsRules,
	},
	{
		/* The AMD-wrap processor lints a virtual `<name>.js.wrapped` file, not the
		 * module on disk. Attach the same environment and rules to that virtual
		 * filename, otherwise no rule (no-undef, semi, no-eval, …) ever applies. */
		files: ['**/*.js.wrapped'],
		languageOptions: shippedJsLanguageOptions,
		rules: shippedJsRules,
	},
];

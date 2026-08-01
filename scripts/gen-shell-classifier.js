#!/usr/bin/env node
'use strict';

/**
 * Emit POSIX fwlive-is-firewall-event.sh from core CLASSIFY_SPEC.
 * Usage: node scripts/gen-shell-classifier.js > path/to/fwlive-is-firewall-event.sh
 */

const path = require('node:path');
const core = require(path.join(__dirname, '..', 'core', 'fwlive-log.js'));
const SPEC = core.CLASSIFY_SPEC;

function emitNormalize() {
	const lines = SPEC.glueKeys.map(function(k) {
		return "\t\t-e 's/\\([^[:space:]]\\)\\(" + k + "=\\)/\\1 \\2/g' \\";
	});
	lines[lines.length - 1] = lines[lines.length - 1].replace(/ \\$/, '');
	return [
		'normalize_nf_msg() {',
		"\tprintf '%s' \"$1\" | sed \\",
		...lines,
		'}'
	].join('\n');
}

function emitDetectAction() {
	const alt = SPEC.actionWords.join('|');
	return [
		'_detect_action() {',
		'\tmsg="$1"',
		"\taction=$(printf '%s' \"$msg\" | grep -ioE '(^|[^A-Za-z0-9_])(" + alt + ")([^A-Za-z0-9_]|$)' \\",
		"\t\t| head -1 | sed 's/^[^A-Za-z]*//;s/[^A-Za-z]*$//')",
		'\t[ -n "$action" ] || action=UNKNOWN',
		"\tprintf '%s' \"$action\"",
		'}'
	].join('\n');
}

function emitHasKv() {
	return [
		'_has_kv() {',
		"\tprintf '%s' \"$1\" | grep -qE \"(^|[^A-Za-z0-9_])$2=\"",
		'}'
	].join('\n');
}

function emitHint() {
	const alt = SPEC.firewallHints.join('|');
	return [
		'_has_firewall_hint() {',
		"\tprintf '%s' \"$1\" | grep -qiE '(^|[^A-Za-z0-9_])(" + alt + ")([^A-Za-z0-9_]|$)'",
		'}'
	].join('\n');
}

function emitPrefixCase() {
	/* Match JS NON_FIREWALL_PREFIX: prefix at start, then non-word or end — not prefix*. */
	const pats = SPEC.nonFirewallPrefixes.map(function(p) {
		return p + '|' + p + '[!A-Za-z0-9_]*';
	}).join('|');
	return [
		"\tmsg_lc=$(printf '%s' \"$msg\" | tr '[:upper:]' '[:lower:]')",
		'\tcase "$msg_lc" in',
		'\t\t' + pats + ') return 1 ;;',
		'\tesac'
	].join('\n');
}

function emitAndRule(node, indent) {
	const pad = indent || '\t';
	const parts = node.and.map(function(n) {
		if (n.kv)
			return n.kv.map(function(k) { return '_has_kv "$msg" ' + k; }).join(' && ');
		if (n.kvAny)
			return '{ ' + n.kvAny.map(function(k) { return '_has_kv "$msg" ' + k; }).join(' || ') + '; }';
		if (n.action === 'known')
			return '[ "$action" != "UNKNOWN" ]';
		if (n.hint)
			return '_has_firewall_hint "$msg"';
		return 'false';
	});
	return pad + 'if ' + parts.join(' && ') + '; then\n' + pad + '\treturn 0\n' + pad + 'fi';
}

function emitDecisionTree() {
	const chunks = [];
	chunks.push('\taction=$(_detect_action "$msg")');
	chunks.push('');
	for (let i = 0; i < SPEC.rules.length; i++) {
		const rule = SPEC.rules[i];
		if (rule.or) {
			for (let j = 0; j < rule.or.length; j++)
				chunks.push(emitAndRule(rule.or[j], '\t'));
		} else if (rule.and) {
			chunks.push(emitAndRule(rule, '\t'));
		}
		chunks.push('');
	}
	chunks.push('\treturn 1');
	return chunks.join('\n');
}

function emitIsFirewall() {
	return [
		'is_firewall_event_msg() {',
		'\tmsg=$(normalize_nf_msg "$1")',
		"\tmsg=$(printf '%s' \"$msg\" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')",
		'\t[ -n "$msg" ] || return 1',
		'',
		emitPrefixCase(),
		'',
		emitDecisionTree(),
		'}'
	].join('\n');
}

const out = [
	'# SPDX-License-Identifier: Apache-2.0',
	'# Copyright 2025-2026 Lucas Albers <lucas.b.albers@gmail.com>',
	'#',
	'# GENERATED FILE — do not edit. Run: ./scripts/gen-all.sh',
	'# source: core/fwlive-log.js CLASSIFY_SPEC',
	'# Shared isFirewallEvent parity logic (shell). Sourced by fwlive-log-filter.sh and tests.',
	'',
	emitNormalize(),
	'',
	emitDetectAction(),
	'',
	emitHasKv(),
	'',
	emitHint(),
	'',
	emitIsFirewall(),
	''
].join('\n');

process.stdout.write(out);

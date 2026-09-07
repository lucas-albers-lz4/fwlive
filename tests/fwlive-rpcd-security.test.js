#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const ROOT = path.join(__dirname, '..');
const RPCD = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive');
const ACL = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/share/rpcd/acl.d/luci-app-fwlive.json');
const LOGGING_TEST = path.join(ROOT, 'tests/fwlive-logging.test.sh');

const acl = JSON.parse(fs.readFileSync(ACL, 'utf8'));
const readUbus = acl['luci-app-fwlive']?.read?.ubus || {};
if (Object.prototype.hasOwnProperty.call(readUbus, 'log')) {
	console.error('ACL must not grant ubus log.* (poll uses root log.read inside rpcd)');
	process.exit(1);
}
if (!Array.isArray(readUbus.fwlive) || !readUbus.fwlive.includes('poll')) {
	console.error('ACL must grant fwlive.poll for Luci sessions');
	process.exit(1);
}

const out = execFileSync('sh', [RPCD, '__selftest'], { encoding: 'utf8' });
if (out.includes('skip:'))
	console.log('fwlive rpcd security: ' + out.trim());

execFileSync('bash', [LOGGING_TEST], { stdio: 'inherit' });

// --- #303 fail-closed structured error contract (host) ---
//
// Every rpcd method's fail-closed path must emit a non-empty `error` field,
// never a silent empty success shape. These tests drive the production rpcd
// script with stubbed PATH entries to force each failure, then assert the
// reply carries `error`. Logging_status is the intentional exception: it
// signals state via blockers/warnings + ready (pinned as full-shape below).

function makeStub(dir, name, content) {
	const p = path.join(dir, name);
	fs.writeFileSync(p, content, { mode: 0o755 });
}

function makePassthrough(dir, name, real) {
	makeStub(dir, name, `#!/bin/sh\nexec ${real} "$@"\n`);
}

function runCall(args, opts) {
	for (const p of ['/bin/dash', '/usr/bin/dash', 'dash']) {
		try {
			return execFileSync(p, [RPCD, ...args], opts);
		} catch (e) {
			if (e.code !== 'ENOENT') throw e;
		}
	}
	throw new Error('dash not found for runCall');
}

function assertStructuredError(res, method) {
	assert.equal(typeof res.error, 'string',
		`[${method}] reply must carry an error field, got: ${JSON.stringify(res)}`);
	assert.ok(res.error.length > 0, `[${method}] error must be non-empty`);
}

function testUnknownMethod() {
	let failed = false;
	let raw = '';
	try {
		execFileSync('sh', [RPCD, 'call', 'no_such_method_303'],
			{ encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
	} catch (e) {
		failed = e.status !== 0;
		raw = String(e.stdout || '');
	}
	assert.equal(failed, true, 'unknown method must exit non-zero');
	assertStructuredError(JSON.parse(raw), 'unknown-method');
}

function testRulesNoBackend() {
	// nft fails and iptables-save is absent from PATH, so detection yields
	// unknown. Assumes the host has no real iptables-save (true on Ubuntu
	// CI runners and containers; OpenWrt device CI must keep it so).
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-nobe-'));
	try {
		makePassthrough(stubDir, 'dirname', '/usr/bin/dirname');
		makePassthrough(stubDir, 'sed', '/usr/bin/sed');
		makeStub(stubDir, 'nft', '#!/bin/sh\nexit 1\n');
		makeStub(stubDir, 'uci', '#!/bin/sh\nexit 0\n');
		const env = { ...process.env, PATH: stubDir };
		const raw = runCall(['call', 'rules'], { encoding: 'utf8', env });
		const res = JSON.parse(raw);
		assert.equal(res.backend, 'unknown');
		assertStructuredError(res, 'rules/no_backend');
		assert.equal(res.error, 'no_backend');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function testRulesNftDumpFailure() {
	// Stateful nft: the detect probe (first call) succeeds empty so the
	// backend is nft, then the dump (second call) fails. Catches a dump
	// failure degrading into a silent empty rules map.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-nftf-'));
	try {
		makeStub(stubDir, 'nft', `#!/bin/sh
state="${stubDir}/nft.calls"
n="$(/bin/cat "$state" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$state"
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
	if [ "$n" -eq 0 ]; then exit 0; fi
	exit 1
fi
exit 1
`);
		makeStub(stubDir, 'uci', '#!/bin/sh\nexit 0\n');
		const env = { ...process.env, PATH: `${stubDir}:/usr/bin:/bin` };
		const raw = runCall(['call', 'rules'], { encoding: 'utf8', env });
		const res = JSON.parse(raw);
		assert.equal(res.backend, 'nft');
		assertStructuredError(res, 'rules/nft_failed');
		assert.equal(res.error, 'nft_failed');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function testRulesIptablesDumpFailure() {
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-iptf-'));
	try {
		makeStub(stubDir, 'nft', '#!/bin/sh\nexit 1\n');
		makeStub(stubDir, 'iptables-save', '#!/bin/sh\nexit 1\n');
		// ip6tables-save not stubbed -> command -v returns false -> skipped
		// (tests the IPv4-only failure path so ip6tables_failed isn't masked
		// by an unrelated stub)
		makeStub(stubDir, 'uci', '#!/bin/sh\nexit 0\n');
		const env = { ...process.env, PATH: `${stubDir}:/usr/bin:/bin` };
		const raw = runCall(['call', 'rules'], { encoding: 'utf8', env });
		const res = JSON.parse(raw);
		assert.equal(res.backend, 'iptables');
		assertStructuredError(res, 'rules/iptables_failed');
		assert.equal(res.error, 'iptables_failed');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function testRulesIp6tablesDumpFailure() {
	// ip6tables-save present and failing must surface ip6tables_failed even
	// when the IPv4 dump succeeded: a partial-success map must not look
	// healthy to the UI.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-ip6f-'));
	try {
		makeStub(stubDir, 'nft', '#!/bin/sh\nexit 1\n');
		makeStub(stubDir, 'iptables-save', `#!/bin/sh
cat <<'EOF'
-A INPUT -j LOG --log-prefix "ipv4-only"
EOF
`);
		makeStub(stubDir, 'ip6tables-save', '#!/bin/sh\nexit 1\n');
		makeStub(stubDir, 'uci', '#!/bin/sh\nexit 0\n');
		const env = { ...process.env, PATH: `${stubDir}:/usr/bin:/bin` };
		const raw = runCall(['call', 'rules'], { encoding: 'utf8', env });
		const res = JSON.parse(raw);
		assert.equal(res.backend, 'iptables');
		assertStructuredError(res, 'rules/ip6tables_failed');
		assert.equal(res.error, 'ip6tables_failed');
		// IPv4 enrichment must still be present: a failed ip6 dump must not
		// mask the IPv4 rules that did make it through.
		assert.equal(res.rules['ipv4-only'], 'ipv4 only');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function testPollUbusFailure() {
	// Dead logd must surface log_read_failed, not an empty table that looks
	// like "no firewall events". The reply bypasses the filter, so this is
	// deterministic with or without jsonfilter on PATH.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-poll-'));
	try {
		makeStub(stubDir, 'ubus', '#!/bin/sh\nexit 1\n');
		const env = { ...process.env, PATH: `${stubDir}:/usr/bin:/bin` };
		const raw = runCall(['call', 'poll', '{"addresses":["50"]}'],
			{ encoding: 'utf8', env });
		const res = JSON.parse(raw);
		assert.ok(Array.isArray(res.log), 'poll failure must keep the log shape');
		assertStructuredError(res, 'poll/log_read_failed');
		assert.equal(res.error, 'log_read_failed');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function testResolveJshnMissing() {
	// Isolated PATH: nslookup present (stub) so the resolver check passes,
	// jshn absent so the JSON-dependency failure must carry an error.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-nojshn-'));
	try {
		makePassthrough(stubDir, 'dirname', '/usr/bin/dirname');
		makePassthrough(stubDir, 'date', '/bin/date');
		makePassthrough(stubDir, 'cat', '/bin/cat');
		makeStub(stubDir, 'nslookup', '#!/bin/sh\nexit 0\n');
		const env = { ...process.env, PATH: stubDir };
		const raw = runCall(['call', 'resolve', '{"addresses":["192.0.2.1"]}'],
			{ encoding: 'utf8', env });
		const res = JSON.parse(raw);
		assert.deepEqual(res.names, {});
		assertStructuredError(res, 'resolve/jshn_missing');
		assert.equal(res.error, 'jshn_missing');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function testResolveInvalidInput() {
	// Needs jshn on PATH (production checks `command -v jshn`); the libubox
	// source file alone is not enough. Stock hosts without jshn skip,
	// matching the __selftest jshn skip.
	//
	// Production guards nslookup first (no_resolver). On a host that has
	// jshn but no nslookup, the call would exit at no_resolver before the
	// malformed-input branch ever runs. Pin a working nslookup stub so the
	// invalid_input path is the one under test, regardless of host PATH.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-inv-'));
	let hasJshn = false;
	try {
		execFileSync('sh', ['-c', 'command -v jshn >/dev/null 2>&1'], { stdio: 'ignore' });
		hasJshn = true;
	} catch {}
	if (!hasJshn) {
		fs.rmSync(stubDir, { recursive: true, force: true });
		console.log('fwlive rpcd security: skip invalid_input (jshn not available)');
		return;
	}
	try {
		makeStub(stubDir, 'nslookup', '#!/bin/sh\nexit 0\n');
		const raw = runCall(['call', 'resolve', 'not-json{{{'], {
			encoding: 'utf8',
			env: { ...process.env, PATH: `${stubDir}:${process.env.PATH}` }
		});
		const res = JSON.parse(raw);
		assertStructuredError(res, 'resolve/invalid_input');
		assert.equal(res.error, 'invalid_input');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function testLoggingStatusNeverSilent() {
	// logging_status has no error field by design: failures travel as
	// blockers/warnings with ready=false. Pin the full shape so a regression
	// can never degrade into a silent empty object.
	const raw = runCall(['call', 'logging_status'], { encoding: 'utf8' });
	const res = JSON.parse(raw);
	for (const k of ['wan_zone', 'wan_log', 'wan_log_limit',
		'nf_log_ipv4', 'nf_log_ipv6', 'ready', 'blockers', 'warnings']) {
		assert.ok(Object.prototype.hasOwnProperty.call(res, k),
			`logging_status must always carry ${k}, got: ${raw}`);
	}
	assert.equal(typeof res.ready, 'boolean');
	assert.ok(Array.isArray(res.blockers));
	assert.ok(Array.isArray(res.warnings));
}

function testToggleNoWanZone() {
	// uci returns no zones: both write-ACL methods must fail closed with
	// no_wan_zone before touching the lock. Pin the lock file path so the
	// pre-lock short-circuit is observable (any lock acquisition would
	// create the file).
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-nowan-'));
	const lockDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-nowan-lock-'));
	const lockFile = path.join(lockDir, 'logging.lock');
	try {
		makeStub(stubDir, 'uci', '#!/bin/sh\nexit 0\n');
		const env = {
			...process.env,
			PATH: `${stubDir}:/usr/bin:/bin`,
			FWLIVE_WAN_LOG_LOCK_FILE: lockFile
		};
		for (const method of ['enable_wan_logging', 'disable_wan_logging']) {
			const raw = runCall(['call', method], { encoding: 'utf8', env });
			const res = JSON.parse(raw);
			assert.equal(res.ok, false);
			assertStructuredError(res, `${method}/no_wan_zone`);
			assert.equal(res.error, 'no_wan_zone');
			assert.ok(!fs.existsSync(lockFile),
				`${method} must not touch the lock before finding a WAN zone`);
		}
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
		fs.rmSync(lockDir, { recursive: true, force: true });
	}
}

testUnknownMethod();
testRulesNoBackend();
testRulesNftDumpFailure();
testRulesIptablesDumpFailure();
testRulesIp6tablesDumpFailure();
testPollUbusFailure();
testResolveJshnMissing();
testResolveInvalidInput();
testLoggingStatusNeverSilent();
testToggleNoWanZone();

console.log('fwlive rpcd security: OK');

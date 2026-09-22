#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const ROOT = path.join(__dirname, '..');
const RPCD = path.join(ROOT, 'openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive');
const ACL = path.join(
	ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/share/rpcd/acl.d/luci-app-fwlive.json'
);
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

function shellQuote(value) {
	return "'" + value.replaceAll("'", "'\"'\"'") + "'";
}

function assertSelftestResult(result) {
	assert.ifError(result.error);
	assert.equal(result.status, 0, `rpcd selftest failed: ${result.stderr || result.stdout}`);
	const output = `${result.stdout || ''}\n${result.stderr || ''}`;
	assert.doesNotMatch(output, /skip:/, 'rpcd selftest must execute with matched jshn');
	return output;
}

function runMatchedRpcdSelftest(prefix, release = process.env.FWLIVE_JSHN_RELEASE || '24.10') {
	const busybox = 'busybox';
	prefix = prefix || process.env.FWLIVE_JSHN_PREFIX || path.join(os.homedir(), '.cache/fwlive-jshn');
	assert.match(release, /^(23\.05|24\.10|25\.12)$/, 'unsupported FWLIVE_JSHN_RELEASE');

	const pair = path.join(prefix, release);
	const jshn = path.join(pair, 'bin', 'jshn');
	const jshnSh = path.join(pair, 'share', 'jshn.sh');
	const jshnStat = fs.existsSync(jshn) && fs.statSync(jshn);
	assert.ok(jshnStat && jshnStat.isFile(), `matched jshn binary missing: ${jshn}`);
	assert.ok((jshnStat.mode & 0o111) !== 0, `matched jshn binary is not executable: ${jshn}`);
	const jshnShStat = fs.existsSync(jshnSh) && fs.statSync(jshnSh);
	assert.ok(jshnShStat && jshnShStat.isFile(), `matched jshn shell library missing: ${jshnSh}`);

	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-rpcd-selftest-'));
	try {
		const libexec = path.join(work, 'libexec');
		fs.cpSync(path.dirname(path.dirname(RPCD)), libexec, { recursive: true });
		const plugin = path.join(libexec, 'rpcd', 'fwlive');
		const source = fs
			.readFileSync(RPCD, 'utf8')
			.replaceAll('/usr/share/libubox/jshn.sh', () => shellQuote(jshnSh));
		fs.writeFileSync(plugin, source, { mode: 0o755 });
		fs.chmodSync(plugin, 0o755);
		const env = {
			...process.env,
			PATH: `${path.dirname(jshn)}:${process.env.PATH || ''}`,
		};
		const resolved = execFileSync(busybox, ['sh', '-c', 'command -v jshn'], {
			encoding: 'utf8',
			env,
		}).trim();
		assert.equal(fs.realpathSync(resolved), fs.realpathSync(jshn), 'selected jshn must win PATH resolution');
		return assertSelftestResult(
			spawnSync(busybox, ['sh', plugin, '__selftest'], { encoding: 'utf8', env })
		);
	} finally {
		fs.rmSync(work, { recursive: true, force: true });
	}
}

function testSelftestHarnessBoundaries() {
	const prefix = process.env.FWLIVE_JSHN_PREFIX || path.join(os.homedir(), '.cache/fwlive-jshn');
	const release = process.env.FWLIVE_JSHN_RELEASE || '24.10';
	const sourcePair = path.join(prefix, release);
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-rpcd-harness-'));
	try {
		const spacedPrefix = path.join(work, "prefix with spaces $& $$ 'quote'");
		fs.mkdirSync(spacedPrefix, { recursive: true });
		fs.cpSync(sourcePair, path.join(spacedPrefix, release), { recursive: true });
		assert.doesNotThrow(
			() => runMatchedRpcdSelftest(spacedPrefix, release),
			'jshn prefixes containing spaces must be supported'
		);

		const skip = path.join(work, 'skip-selftest');
		fs.writeFileSync(skip, '#!/bin/sh\nprintf "skip: fake\\n" >&2\nexit 0\n', { mode: 0o755 });
		fs.chmodSync(skip, 0o755);
		assert.throws(
			() => assertSelftestResult(spawnSync(skip, [], { encoding: 'utf8' })),
			/must execute/,
			'stderr-only skip must fail the harness'
		);

		const badPrefix = path.join(work, 'bad-prefix');
		const badPair = path.join(badPrefix, release);
		fs.mkdirSync(path.join(badPair, 'bin'), { recursive: true });
		fs.mkdirSync(path.join(badPair, 'share'), { recursive: true });
		fs.copyFileSync(path.join(sourcePair, 'share', 'jshn.sh'), path.join(badPair, 'share', 'jshn.sh'));
		const badJshn = path.join(badPair, 'bin', 'jshn');
		fs.writeFileSync(badJshn, '#!/bin/sh\nexit 0\n', { mode: 0o644 });
		const fallbackBin = path.join(work, 'fallback-bin');
		fs.mkdirSync(fallbackBin);
		fs.writeFileSync(path.join(fallbackBin, 'jshn'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
		const oldPath = process.env.PATH;
		process.env.PATH = `${fallbackBin}:${oldPath || ''}`;
		try {
			assert.throws(
				() => runMatchedRpcdSelftest(badPrefix, release),
				/not executable/,
				'non-executable selected jshn must fail even with another jshn on PATH'
			);
		} finally {
			process.env.PATH = oldPath;
		}
	} finally {
		fs.rmSync(work, { recursive: true, force: true });
	}
}

testSelftestHarnessBoundaries();
const out = runMatchedRpcdSelftest();
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
	assert.equal(
		typeof res.error,
		'string',
		`[${method}] reply must carry an error field, got: ${JSON.stringify(res)}`
	);
	assert.ok(res.error.length > 0, `[${method}] error must be non-empty`);
}

function testAclMethodParity() {
	const listed = JSON.parse(execFileSync('sh', [RPCD, 'list'], { encoding: 'utf8' }));
	const methods = Object.keys(listed).sort();
	const read = [...(readUbus.fwlive || [])].sort();
	const write = [...(acl['luci-app-fwlive']?.write?.ubus?.fwlive || [])].sort();
	const granted = read.concat(write).sort();

	assert.equal(new Set(read).size, read.length, 'read ACL must not duplicate methods');
	assert.equal(new Set(write).size, write.length, 'write ACL must not duplicate methods');
	assert.deepEqual(
		read.filter(function (method) {
			return write.includes(method);
		}),
		[],
		'read and write ACL scopes must remain separate'
	);
	assert.deepEqual(
		read,
		['logging_status', 'poll', 'resolve', 'rules'],
		'read ACL must own exactly the read methods'
	);
	assert.deepEqual(
		write,
		['disable_wan_logging', 'enable_wan_logging'],
		'write ACL must own exactly the write methods'
	);
	assert.deepEqual(granted, methods, 'ACL methods must match the rpcd method list');
}

function testUnknownMethod() {
	let failed = false;
	let raw = '';
	try {
		execFileSync('sh', [RPCD, 'call', 'no_such_method_303'], {
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'pipe']
		});
	} catch (e) {
		failed = e.status !== 0;
		raw = String(e.stdout || '');
	}
	assert.equal(failed, true, 'unknown method must exit non-zero');
	assertStructuredError(JSON.parse(raw), 'unknown-method');
}

function testRulesNoBackend() {
	// nft fails, so detection yields unknown. There is no iptables-save
	// fallback (#378 Phase 2).
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

function testRulesNftAbsent() {
	// command -v nft fails when the binary is missing, not only when it
	// exits non-zero. Same unknown/no_backend contract as a failed nft.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-nonft-'));
	try {
		makePassthrough(stubDir, 'dirname', '/usr/bin/dirname');
		makePassthrough(stubDir, 'sed', '/usr/bin/sed');
		makeStub(stubDir, 'uci', '#!/bin/sh\nexit 0\n');
		const env = { ...process.env, PATH: stubDir };
		const raw = runCall(['call', 'rules'], { encoding: 'utf8', env });
		const res = JSON.parse(raw);
		assert.equal(res.backend, 'unknown');
		assertStructuredError(res, 'rules/nft_absent');
		assert.equal(res.error, 'no_backend');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function testRemovedRulesmapIptablesCli() {
	let failed = false;
	let raw = '';
	try {
		execFileSync('sh', [RPCD, '__rulesmap_iptables'], {
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'pipe']
		});
	} catch (e) {
		failed = e.status !== 0;
		raw = String(e.stdout || '');
	}
	assert.equal(failed, true, 'removed __rulesmap_iptables must exit non-zero');
	assert.equal(raw.trim(), '', 'removed CLI hook must not emit a rules map');
}

function testRulesNftDumpFailure() {
	// Stateful nft: the detect probe (first call) succeeds empty so the
	// backend is nft, then the dump (second call) fails. Catches a dump
	// failure degrading into a silent empty rules map.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-nftf-'));
	try {
		makeStub(
			stubDir,
			'nft',
			`#!/bin/sh
state="${stubDir}/nft.calls"
n="$(/bin/cat "$state" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$state"
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
	if [ "$n" -eq 0 ]; then exit 0; fi
	exit 1
fi
exit 1
`
		);
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

function testRulesNoIptablesFallback() {
	// nft fails; iptables-save / ip6tables-save on PATH must not become the
	// rules backend or be invoked (#378 Phase 2).
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-nobe-ipt-'));
	try {
		makeStub(stubDir, 'nft', '#!/bin/sh\nexit 1\n');
		makeStub(
			stubDir,
			'iptables-save',
			`#!/bin/sh
echo called >> "${stubDir}/ipt-called"
exit 1
`
		);
		makeStub(
			stubDir,
			'ip6tables-save',
			`#!/bin/sh
echo called >> "${stubDir}/ip6-called"
exit 1
`
		);
		makeStub(stubDir, 'uci', '#!/bin/sh\nexit 0\n');
		const env = { ...process.env, PATH: `${stubDir}:/usr/bin:/bin` };
		const raw = runCall(['call', 'rules'], { encoding: 'utf8', env });
		const res = JSON.parse(raw);
		assert.equal(res.backend, 'unknown');
		assertStructuredError(res, 'rules/no_backend');
		assert.equal(res.error, 'no_backend');
		assert.equal(
			fs.existsSync(path.join(stubDir, 'ipt-called')),
			false,
			'iptables-save must not run'
		);
		assert.equal(
			fs.existsSync(path.join(stubDir, 'ip6-called')),
			false,
			'ip6tables-save must not run'
		);
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function testPollUbusFailure() {
	// Dead logd must surface log_read_failed, not an empty table that looks
	// like "no firewall events". The reply bypasses the filter, so this is
	// deterministic with or without jsonfilter on PATH.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-poll-'));
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-303-adapt-'));
	try {
		makeStub(stubDir, 'ubus', '#!/bin/sh\nexit 1\n');
		const env = {
			...process.env,
			PATH: `${stubDir}:/usr/bin:/bin`,
			FWLIVE_ADAPTIVE: '1',
			FWLIVE_ADAPTIVE_STATE_FILE: path.join(work, 'state.json'),
			FWLIVE_ADAPTIVE_OFF_FILE: path.join(work, 'adaptive-off-absent')
		};
		const raw = runCall(['call', 'poll', '{"addresses":["50"]}'], { encoding: 'utf8', env });
		const res = JSON.parse(raw);
		assert.ok(Array.isArray(res.log), 'poll failure must keep the log shape');
		assertStructuredError(res, 'poll/log_read_failed');
		assert.equal(res.error, 'log_read_failed');
		assert.equal(res.adaptive, 1, 'Layer 1 adaptive reply field');
		assert.equal(
			res.messages_received,
			0,
			'failed log.read must keep the messages_received fallback at 0'
		);
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
		fs.rmSync(work, { recursive: true, force: true });
	}
}

function testPollMessagesReceived() {
	// The filter must count every logd entry enumerated by jsonfilter, not only
	// the firewall rows that survive classification.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-306-count-'));
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-306-count-state-'));
	const fixture = path.join(ROOT, 'tests/fixtures/logread-mixed.json');
	try {
		makeStub(
			stubDir,
			'ubus',
			`#!/bin/sh
exec /bin/cat '${fixture}'
`
		);
		makeStub(
			stubDir,
			'jsonfilter',
			`#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const args = process.argv.slice(2);
const expr = args.indexOf('-e');
if (expr < 0 || args[expr + 1] !== '@.log[*]') process.exit(1);
let data;
try { data = JSON.parse(fs.readFileSync(0, 'utf8')); } catch (e) { process.exit(1); }
for (const entry of (data && Array.isArray(data.log) ? data.log : []))
	process.stdout.write(JSON.stringify(entry) + '\\n');
`
		);
		const env = {
			...process.env,
			/* Keep the runner's Node location available to the jsonfilter stub;
			 * hosted runners may not install node in /usr/bin. */
			PATH: `${stubDir}:${process.env.PATH || '/usr/bin:/bin'}`,
			FWLIVE_ADAPTIVE: '1',
			FWLIVE_ADAPTIVE_STATE_FILE: path.join(work, 'state.json'),
			FWLIVE_ADAPTIVE_OFF_FILE: path.join(work, 'adaptive-off-absent')
		};
		const raw = runCall(['call', 'poll', '{"addresses":["50"]}'], { encoding: 'utf8', env });
		const res = JSON.parse(raw);
		assert.equal(
			res.messages_received,
			8,
			'poll must report all eight logd entries, including non-firewall rows'
		);
		assert.equal(res.log.length, 5, 'fixture should classify five firewall rows');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
		fs.rmSync(work, { recursive: true, force: true });
	}
}

function testAdaptiveHotSurvivesFailedPoll() {
	// CodeRabbit CR2: hot state + failed ubus poll must keep shed; resolve
	// must return disabled:load (rpcd path, not helper-only).
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-306-hot-'));
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-306-state-'));
	const stateFile = path.join(work, 'state.json');
	try {
		fs.writeFileSync(
			stateFile,
			'{"duration_ms":900,"limit":250,"bucket":"hot","warm_halved":0,"shed":1,"completed_cs":1}\n'
		);
		makeStub(stubDir, 'ubus', '#!/bin/sh\nexit 1\n');
		makeStub(stubDir, 'nslookup', '#!/bin/sh\nexit 0\n');
		makePassthrough(stubDir, 'dirname', '/usr/bin/dirname');
		makePassthrough(stubDir, 'date', '/bin/date');
		makePassthrough(stubDir, 'cat', '/bin/cat');
		const env = {
			...process.env,
			PATH: `${stubDir}:/usr/bin:/bin`,
			FWLIVE_ADAPTIVE: '1',
			FWLIVE_ADAPTIVE_STATE_FILE: stateFile,
			FWLIVE_ADAPTIVE_OFF_FILE: path.join(work, 'adaptive-off-absent')
		};
		const pollRaw = runCall(['call', 'poll', '{"addresses":["50"]}'], {
			encoding: 'utf8',
			env
		});
		const poll = JSON.parse(pollRaw);
		assert.equal(poll.error, 'log_read_failed');
		const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
		assert.equal(state.bucket, 'hot', 'failed poll must not clear hot bucket');
		assert.equal(state.shed, 1, 'failed poll must not clear shed');
		const resolveRaw = runCall(['call', 'resolve', '{"addresses":["192.0.2.1"]}'], {
			encoding: 'utf8',
			env
		});
		const resolve = JSON.parse(resolveRaw);
		assert.deepEqual(resolve.names, {});
		assert.equal(resolve.disabled, 'load', 'resolve must shed when prior poll was hot');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
		fs.rmSync(work, { recursive: true, force: true });
	}
}

function testAdaptiveHotSurvivesFilterFailures() {
	// A filter can fail after log.read succeeded, including a structured
	// classifier_missing body with exit status zero. None of those outcomes is
	// a healthy sample that may clear the adaptive controller's hot state.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-306-filter-'));
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-306-filter-work-'));
	const libexec = path.join(work, 'usr', 'libexec');
	const rpcdDir = path.join(libexec, 'rpcd');
	const fixtureRpcd = path.join(rpcdDir, 'fwlive');
	const fixtureFilter = path.join(libexec, 'fwlive-log-filter.sh');
	const stateFile = path.join(work, 'state.json');
	try {
		fs.mkdirSync(rpcdDir, { recursive: true });
		fs.copyFileSync(RPCD, fixtureRpcd);
		fs.copyFileSync(
			path.join(ROOT, 'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh'),
			path.join(libexec, 'fwlive-logging.sh')
		);
		fs.copyFileSync(
			path.join(ROOT, 'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-adaptive-cap.sh'),
			path.join(libexec, 'fwlive-adaptive-cap.sh')
		);
		fs.chmodSync(fixtureRpcd, 0o755);
		makeStub(stubDir, 'ubus', '#!/bin/sh\nprintf \'{"log":[]}\'\n');

		const cases = [
			{
				name: 'nonzero with error body',
				body: '#!/bin/sh\nprintf \'{"log":[],"error":"filter_failed"}\'\nexit 1\n'
			},
			{
				name: 'temporary-file failure body',
				body: '#!/bin/sh\nprintf \'{"log":[],"error":"filter_tempfile_failed"}\'\nexit 1\n'
			},
			{
				name: 'jsonfilter missing body',
				body: '#!/bin/sh\nprintf \'{"log":[],"error":"jsonfilter_missing"}\'\nexit 1\n'
			},
			{
				name: 'nonzero without output',
				body: '#!/bin/sh\nexit 1\n'
			},
			{
				name: 'empty successful output',
				body: '#!/bin/sh\nexit 0\n'
			},
			{
				name: 'classifier error body with zero exit',
				body: '#!/bin/sh\nprintf \'{"log":[],"error":"classifier_missing"}\'\nexit 0\n'
			}
		];
		for (const test of cases) {
			fs.writeFileSync(
				stateFile,
				'{"duration_ms":900,"limit":250,"bucket":"hot","warm_halved":0,"shed":1,"completed_cs":1}\n'
			);
			fs.writeFileSync(fixtureFilter, test.body, { mode: 0o755 });
			const env = {
				...process.env,
				PATH: `${stubDir}:/usr/bin:/bin`,
				FWLIVE_ADAPTIVE: '1',
				FWLIVE_ADAPTIVE_STATE_FILE: stateFile,
				FWLIVE_ADAPTIVE_OFF_FILE: path.join(work, 'adaptive-off-absent')
			};
			const raw = execFileSync(
				'/bin/dash',
				[fixtureRpcd, 'call', 'poll', '{"addresses":["50"]}'],
				{ encoding: 'utf8', env }
			);
			const res = JSON.parse(raw);
			assert.ok(res.error, `${test.name} must preserve its error reply`);
			assert.equal(
				res.effective_limit,
				undefined,
				`${test.name} must omit effective_limit on errors`
			);
			const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
			assert.equal(state.bucket, 'hot', `${test.name} must preserve hot bucket`);
			assert.equal(state.shed, 1, `${test.name} must preserve shed state`);
		}
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
		fs.rmSync(work, { recursive: true, force: true });
	}
}

function testSummaryErrorValueDoesNotFailHealthGate() {
	// The summary is data: a talker/rule value may literally be "error".
	// The rpcd health gate must match the structured error key, not that value.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-306-summary-error-'));
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-306-summary-error-work-'));
	const libexec = path.join(work, 'usr', 'libexec');
	const rpcdDir = path.join(libexec, 'rpcd');
	const fixtureRpcd = path.join(rpcdDir, 'fwlive');
	const fixtureFilter = path.join(libexec, 'fwlive-log-filter.sh');
	const stateFile = path.join(work, 'state.json');
	try {
		fs.mkdirSync(rpcdDir, { recursive: true });
		fs.copyFileSync(RPCD, fixtureRpcd);
		fs.copyFileSync(
			path.join(ROOT, 'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh'),
			path.join(libexec, 'fwlive-logging.sh')
		);
		fs.copyFileSync(
			path.join(ROOT, 'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-adaptive-cap.sh'),
			path.join(libexec, 'fwlive-adaptive-cap.sh')
		);
		fs.chmodSync(fixtureRpcd, 0o755);
		makeStub(stubDir, 'ubus', '#!/bin/sh\nprintf \'{"log":[{"msg":"fw4: DROP IN=wan OUT= SRC=error DST=192.0.2.1 PROTO=TCP"}]}\'\n');
		fs.writeFileSync(fixtureFilter, [
			'#!/bin/sh',
			'printf \'{"log":[{"msg":"fw4: DROP IN=wan OUT= SRC=error DST=192.0.2.1 PROTO=TCP"}],"messages_received":1,"summary":{"scope":"top of shown sample","top_talkers":[{"value":"error","count":1}],"top_drops":[],"top_rules":[]}}\'',
			''
		].join('\n'), { mode: 0o755 });
		fs.writeFileSync(
			stateFile,
			'{"duration_ms":900,"limit":250,"bucket":"hot","warm_halved":0,"shed":1,"completed_cs":1}\n'
		);
		const env = {
			...process.env,
			PATH: `${stubDir}:/usr/bin:/bin`,
			FWLIVE_ADAPTIVE: '1',
			FWLIVE_ADAPTIVE_STATE_FILE: stateFile,
			FWLIVE_ADAPTIVE_OFF_FILE: path.join(work, 'adaptive-off-absent')
		};
		const raw = execFileSync(
			'/bin/dash',
			[fixtureRpcd, 'call', 'poll', '{"addresses":["50"]}'],
			{ encoding: 'utf8', env }
		);
		const res = JSON.parse(raw);
		assert.equal(res.error, undefined, 'summary value "error" must not create a filter error');
		const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
		assert.notEqual(state.bucket, 'hot', 'healthy summary value must record adaptive state');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
		fs.rmSync(work, { recursive: true, force: true });
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
		const raw = runCall(['call', 'resolve', '{"addresses":["192.0.2.1"]}'], {
			encoding: 'utf8',
			env
		});
		const res = JSON.parse(raw);
		assert.deepEqual(res.names, {});
		assertStructuredError(res, 'resolve/jshn_missing');
		assert.equal(res.error, 'jshn_missing');
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

// Malformed JSON is mandatory in fwlive-jshn-compat.test.py for every real
// release pair under ash; do not add a host-dependent skip here.

function testLoggingStatusNeverSilent() {
	// logging_status has no error field by design: failures travel as
	// blockers/warnings with ready=false. Pin the full shape so a regression
	// can never degrade into a silent empty object.
	const raw = runCall(['call', 'logging_status'], { encoding: 'utf8' });
	const res = JSON.parse(raw);
	for (const k of [
		'wan_zone',
		'wan_zone_candidates',
		'wan_log',
		'wan_log_limit',
		'nf_log_ipv4',
		'nf_log_ipv6',
		'ready',
		'weak_device',
		'blockers',
		'warnings'
	]) {
		assert.ok(
			Object.prototype.hasOwnProperty.call(res, k),
			`logging_status must always carry ${k}, got: ${raw}`
		);
	}
	assert.equal(typeof res.ready, 'boolean');
	assert.equal(typeof res.weak_device, 'boolean');
	assert.ok(Array.isArray(res.blockers));
	assert.ok(Array.isArray(res.warnings));
	assert.ok(Array.isArray(res.wan_zone_candidates));
	assert.ok(
		!Object.prototype.hasOwnProperty.call(res, 'error'),
		'logging_status must not carry an error field (intentional exception)'
	);
}

function makeNfLogFixtures(workDir) {
	const nfLog4 = path.join(workDir, 'nf-log-4');
	const nfLog6 = path.join(workDir, 'nf-log-6');
	const inet6 = path.join(workDir, 'if-inet6');
	fs.writeFileSync(nfLog4, 'nf_log_ipv4\n');
	fs.writeFileSync(nfLog6, 'nf_log_ipv6\n');
	fs.writeFileSync(inet6, '00000000000000000000000000000001 01 80 lo\n');
	return { nfLog4, nfLog6, inet6 };
}

function makeWanUciStub(stubDir, mutationMarker, logValue) {
	const log = logValue === undefined ? '' : String(logValue);
	makeStub(
		stubDir,
		'uci',
		`#!/bin/sh
marker="${mutationMarker}"
log_value="${log}"
case "$*" in
	'-q show firewall')
		printf "firewall.@zone[0]=zone\\nfirewall.@zone[0].name='wan'\\n"
		;;
	'-q get firewall.@zone[0]')
		printf 'zone\\n'
		;;
	'-q get firewall.@zone[0].name')
		printf 'wan\\n'
		;;
	'-q get firewall.@zone[0].network')
		printf 'wan\\n'
		;;
	'-q get firewall.@zone[0].log')
		printf '%s' "$log_value"
		;;
	'-q changes firewall')
		return 1
		;;
	'set firewall.'*|'delete firewall.'*|'commit firewall')
		printf '%s\\n' "$*" >>"$marker"
		return 0
		;;
	*)
		return 1
		;;
esac
`
	);
}

function testToggleLockFailed() {
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-391-lock-'));
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-391-lock-work-'));
	const lockDir = path.join(work, 'lock');
	const lockFile = path.join(lockDir, 'logging.lock');
	const mutationMarker = path.join(work, 'uci-mutations');
	const nf = makeNfLogFixtures(work);
	fs.mkdirSync(lockDir, { recursive: true });
	fs.symlinkSync('/dev/null', lockFile);
	makeWanUciStub(stubDir, mutationMarker, '2');
	try {
		const env = {
			...process.env,
			PATH: `${stubDir}:/usr/bin:/bin`,
			FWLIVE_WAN_LOG_LOCK_FILE: lockFile,
			FWLIVE_NF_LOG_IPV4_PATH: nf.nfLog4,
			FWLIVE_NF_LOG_IPV6_PATH: nf.nfLog6,
			FWLIVE_IPV6_AVAILABLE_PATH: nf.inet6
		};
		for (const method of ['enable_wan_logging', 'disable_wan_logging']) {
			const raw = runCall(['call', method], { encoding: 'utf8', env });
			const res = JSON.parse(raw);
			assert.equal(res.ok, false, `[${method}] lock failure must not report success`);
			assertStructuredError(res, `${method}/lock_failed`);
			assert.equal(res.error, 'lock_failed');
			assert.equal(
				fs.existsSync(mutationMarker) ? fs.readFileSync(mutationMarker, 'utf8').trim() : '',
				'',
				`${method} must not stage or commit UCI on lock failure`
			);
		}
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
		fs.rmSync(work, { recursive: true, force: true });
	}
}

function testToggleBaselineSnapshotFailed() {
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-391-base-'));
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-391-base-work-'));
	const lockDir = path.join(work, 'lock');
	const lockFile = path.join(lockDir, 'logging.lock');
	const baselineDir = path.join(work, 'baseline');
	const baselineFile = path.join(baselineDir, 'wan-log-baseline');
	const mutationMarker = path.join(work, 'uci-mutations');
	const nf = makeNfLogFixtures(work);
	fs.mkdirSync(lockDir, { recursive: true });
	// A regular file at the directory path makes mkdir -p fail for every uid,
	// including root; DAC-based chmod failures do not reproduce under root.
	fs.writeFileSync(baselineDir, 'not a directory\n');
	makeWanUciStub(stubDir, mutationMarker, '');
	try {
		const env = {
			...process.env,
			PATH: `${stubDir}:/usr/bin:/bin`,
			FWLIVE_WAN_LOG_LOCK_FILE: lockFile,
			FWLIVE_WAN_LOG_BASELINE_FILE: baselineFile,
			FWLIVE_NF_LOG_IPV4_PATH: nf.nfLog4,
			FWLIVE_NF_LOG_IPV6_PATH: nf.nfLog6,
			FWLIVE_IPV6_AVAILABLE_PATH: nf.inet6
		};
		const raw = runCall(['call', 'enable_wan_logging'], { encoding: 'utf8', env });
		const res = JSON.parse(raw);
		assert.equal(res.ok, false, 'baseline snapshot failure must not report success');
		assertStructuredError(res, 'enable_wan_logging/baseline_snapshot_failed');
		assert.equal(res.error, 'baseline_snapshot_failed');
		assert.equal(
			fs.existsSync(mutationMarker) ? fs.readFileSync(mutationMarker, 'utf8').trim() : '',
			'',
			'enable must not stage or commit UCI when baseline snapshot fails'
		);
		assert.ok(
			!fs.existsSync(baselineFile),
			'baseline snapshot failure must not leave a partial baseline file'
		);
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
		fs.rmSync(work, { recursive: true, force: true });
	}
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
			assert.ok(
				!fs.existsSync(lockFile),
				`${method} must not touch the lock before finding a WAN zone`
			);
		}
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
		fs.rmSync(lockDir, { recursive: true, force: true });
	}
}

testUnknownMethod();
testAclMethodParity();
testRulesNoBackend();
testRulesNftAbsent();
testRemovedRulesmapIptablesCli();
testRulesNftDumpFailure();
testRulesNoIptablesFallback();
testPollMessagesReceived();
testPollUbusFailure();
testAdaptiveHotSurvivesFailedPoll();
testAdaptiveHotSurvivesFilterFailures();
testSummaryErrorValueDoesNotFailHealthGate();
testResolveJshnMissing();
testLoggingStatusNeverSilent();
testToggleNoWanZone();
testToggleLockFailed();
testToggleBaselineSnapshotFailed();

console.log('fwlive rpcd security: OK');

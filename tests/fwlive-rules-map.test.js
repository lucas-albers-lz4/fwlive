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
const FILTER_SH = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-log-filter.sh');
const LOGGING_SH = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh');

function makeStub(dir, name, content) {
	const p = path.join(dir, name);
	fs.writeFileSync(p, content, { mode: 0o755 });
}

function runRpcd(shell, args, opts) {
	if (shell === 'busybox') {
		for (const p of ['/usr/bin/busybox', '/bin/busybox', 'busybox']) {
			try {
				return execFileSync(p, ['sh', RPCD, ...args], opts);
			} catch (e) {
				if (e.code !== 'ENOENT') throw e;
			}
		}
		throw new Error('busybox not found for runRpcd');
	}
	// opts.env may restrict PATH (e.g. no_resolver probe); spawn dash by absolute path.
	for (const p of ['/bin/dash', '/usr/bin/dash', 'dash']) {
		try {
			return execFileSync(p, [RPCD, ...args], opts);
		} catch (e) {
			if (e.code !== 'ENOENT') throw e;
		}
	}
	throw new Error('dash not found for runRpcd');
}

function runPosixFile(shell, file, opts) {
	if (shell === 'busybox') {
		for (const p of ['/usr/bin/busybox', '/bin/busybox', 'busybox']) {
			try {
				return execFileSync(p, ['sh', file], opts);
			} catch (e) {
				if (e.code !== 'ENOENT') throw e;
			}
		}
		throw new Error('busybox not found for runPosixFile');
	}
	for (const p of ['/bin/dash', '/usr/bin/dash', 'dash']) {
		try {
			return execFileSync(p, [file], opts);
		} catch (e) {
			if (e.code !== 'ENOENT') throw e;
		}
	}
	throw new Error('dash not found for runPosixFile');
}

function runPosixC(shell, script, opts) {
	if (shell === 'busybox') {
		for (const p of ['/usr/bin/busybox', '/bin/busybox', 'busybox']) {
			try {
				return execFileSync(p, ['sh', '-c', script], opts);
			} catch (e) {
				if (e.code !== 'ENOENT') throw e;
			}
		}
		throw new Error('busybox not found for runPosixC');
	}
	for (const p of ['/bin/dash', '/usr/bin/dash', 'dash']) {
		try {
			return execFileSync(p, ['-c', script], opts);
		} catch (e) {
			if (e.code !== 'ENOENT') throw e;
		}
	}
	throw new Error('dash not found for runPosixC');
}

function resetCalled(stubDir) {
	try { fs.unlinkSync(path.join(stubDir, 'called')); } catch { /* absent */ }
}

function readCalled(stubDir) {
	return fs.readFileSync(path.join(stubDir, 'called'), 'utf8');
}

function hostCommand(name) {
	const out = execFileSync('/bin/sh', ['-c', 'command -v "$1"', 'sh', name], {
		encoding: 'utf8',
	}).trim();
	assert.ok(out, `need host ${name} to exec from PATH stub`);
	return out;
}

function runWithShell(shell, env) {
	// shell is 'dash' or 'busybox' (busybox needs 'sh' arg)
	return runRpcd(shell, ['call', 'rules'], { encoding: 'utf8', env });
}

let _posixShells;
function posixShells() {
	if (_posixShells) return _posixShells;
	const found = [];
	for (const name of ['dash', 'busybox']) {
		try {
			if (name === 'busybox') {
				execFileSync('busybox', ['sh', '-c', 'exit 0']);
			} else {
				execFileSync(name, ['-c', 'exit 0']);
			}
			found.push(name);
		} catch (e) {
			if (e.code !== 'ENOENT') throw e;
		}
	}
	assert.ok(found.length > 0, 'need dash or busybox on PATH for POSIX coverage');
	_posixShells = found;
	return found;
}

function busyboxHonorsPath(cmd) {
	let probe;
	try {
		probe = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-bbpath-'));
		makeStub(probe, cmd, '#!/bin/sh\necho STUB_RAN\nexit 0\n');
		const out = execFileSync('busybox', ['sh', '-c', `${cmd} 192.0.2.1`], {
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'ignore'],
			env: { ...process.env, PATH: `${probe}:${process.env.PATH}` },
		});
		return out.includes('STUB_RAN');
	} catch (e) {
		if (e.code === 'ENOENT') return false;
		return false;
	} finally {
		if (probe) fs.rmSync(probe, { recursive: true, force: true });
	}
}

function pathHonouringShells(cmd) {
	const shells = posixShells().filter((s) => s !== 'busybox' || busyboxHonorsPath(cmd));
	assert.ok(shells.length > 0, `need a PATH-honouring POSIX shell for ${cmd} stub`);
	return shells;
}

function stubPathEnv(stubDir) {
	return { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
}

function installNftUciStubs(stubDir) {
	makeStub(stubDir, 'nft', `#!/bin/sh
[ "$1" = list ] && [ "$2" = ruleset ] || exit 1
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "fwlive-ssh" comment "!fw4: Allow-SSH"
	}
}
EOF
`);
	makeStub(stubDir, 'uci', '#!/bin/sh\nexit 0\n');
}

function assertNftSshRules(shell, raw) {
	const res = JSON.parse(raw);
	assert.equal(res.backend, 'nft', `[${shell}] backend should be nft`);
	assert.equal(res.rules['fwlive-ssh'], 'Allow-SSH', `[${shell}] fwlive-ssh`);
}

function testProductionNft() {
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-nft-'));
	try {
		// stub nft to emit log prefix and fw4 comment (no trailing space to keep keys exact)
		makeStub(stubDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "fwlive-ssh" comment "!fw4: Allow-SSH"
	}
	chain forward {
		log prefix "My Prefix" comment "!fw4: Allow-DNS"
	}
}
EOF
else
	exit 1
fi
`);
		// stub uci to return empty (no extra rules)
		makeStub(stubDir, 'uci', `#!/bin/sh
exit 0
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		const shells = posixShells();
		for (const shell of shells) {
			let raw;
			try {
				raw = runWithShell(shell, env);
			} catch (e) {
				// if shell not available, skip
				if (e.code === 'ENOENT') continue;
				throw e;
			}
			const res = JSON.parse(raw);
			assert.equal(res.backend, 'nft', `[${shell}] backend should be nft`);
			// log prefix labels must reach OUT (catches pipeline-subshell discard; only uci would survive)
			assert.equal(res.rules['fwlive-ssh'], 'Allow-SSH', `[${shell}] fwlive-ssh prefix should map to Allow-SSH`);
			assert.equal(res.rules['My Prefix'], 'Allow-DNS', `[${shell}] My Prefix should map`);
			// slug for "My Prefix" is "my-prefix" (catches missing slug emission)
			assert.equal(res.rules['my-prefix'], 'Allow-DNS', `[${shell}] my-prefix slug`);
			// raw JSON duplicate check: fwlive-ssh slug == raw so only one key (catches unconditional slug add)
			const cnt = (raw.match(/"fwlive-ssh":/g) || []).length;
			assert.equal(cnt, 1, `[${shell}] raw duplicate fwlive-ssh should be 1, got ${cnt} in ${raw}`);
		}
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function testNftPrefixNormalization() {
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-nft-norm-'));
	try {
		// fw4 conventionally emits log prefix "name " with trailing space, and some legacy "name:"
		makeStub(stubDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "fwlive-ssh " comment "!fw4: Allow-SSH"
		log prefix "fwlive-colon:" comment "!fw4: Allow-Colon"
		log prefix "fwlive-lan "
		log prefix "fwlive-trim: "
		comment "!fw4: MyCustomRule"
	}
}
EOF
else
	exit 1
fi
`);
		makeStub(stubDir, 'uci', `#!/bin/sh
exit 0
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		const shells = posixShells();
		for (const shell of shells) {
			let raw;
			try {
				raw = runWithShell(shell, env);
			} catch (e) {
				if (e.code === 'ENOENT') continue;
				throw e;
			}
			const res = JSON.parse(raw);
			assert.equal(res.backend, 'nft', `[${shell}] backend should be nft`);
			// Exact key contract the client uses via parseRuleHint() — must be normalized (catches single-colon strip)
			assert.equal(res.rules['fwlive-ssh'], 'Allow-SSH', `[${shell}] trailing-space nft prefix must normalize to fwlive-ssh`);
			assert.equal(res.rules['fwlive-ssh '], undefined, `[${shell}] buggy trailing-space key must not exist`);
			assert.equal(res.rules['fwlive-ssh-'], undefined, `[${shell}] buggy slug from trailing space must not exist`);
			assert.equal(res.rules['fwlive-colon'], 'Allow-Colon', `[${shell}] trailing-colon nft prefix must normalize to fwlive-colon`);
			assert.equal(res.rules['fwlive-colon:'], undefined, `[${shell}] buggy colon key must not exist`);
			// Cosmetic values must not keep trailing space either (catches normalize only raw key)
			assert.equal(res.rules['fwlive-lan'], 'fwlive lan', `[${shell}] cosmetic fwlive-lan must be trimmed`);
			assert.equal(res.rules['fwlive-lan '], undefined, `[${shell}] cosmetic trailing-space key must not exist`);
			assert.equal(res.rules['fwlive-lan-'], undefined, `[${shell}] cosmetic buggy slug must not exist`);
			assert.equal(res.rules['fwlive-trim'], 'fwlive trim', `[${shell}] cosmetic colon+space must normalize`);
			// fw4 comment-derived case must keep working (catches regression in comment path)
			assert.equal(res.rules['MyCustomRule'], 'MyCustomRule', `[${shell}] fw4 comment-derived label must map`);
			// raw JSON must not contain buggy keys at all
			assert.equal((raw.match(/"fwlive-ssh "/g) || []).length, 0, `[${shell}] raw must not contain buggy trailing-space key`);
			assert.equal((raw.match(/"fwlive-colon:"/g) || []).length, 0, `[${shell}] raw must not contain buggy colon key`);
		}
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function testDuplicateKeys() {
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-dup-'));
	try {
		// prefix already lowercase hyphen-only -> slug == raw -> should not duplicate key in raw JSON
		makeStub(stubDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "fwlive-wan"
	}
}
EOF
else
	exit 1
fi
`);
		makeStub(stubDir, 'uci', `#!/bin/sh
exit 0
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		const shells = posixShells();
		for (const shell of shells) {
			let raw;
			try {
				raw = runWithShell(shell, env);
			} catch (e) {
				if (e.code === 'ENOENT') continue;
				throw e;
			}
			const res = JSON.parse(raw);
			// both lookups must resolve (catches missing raw or slug)
			assert.equal(res.rules['fwlive-wan'], 'fwlive wan', `[${shell}] raw lookup`);
			// slug is same as raw, so same value, but we check raw JSON string has no duplicate key (catches unconditional slug emit)
			const count = (raw.match(/"fwlive-wan":/g) || []).length;
			assert.equal(count, 1, `[${shell}] duplicate key fwlive-wan should appear exactly once, got ${count} in ${raw}`);
		}
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

// --- New tests for R3 findings ---

function testIdempotentNormalization() {
	// Verifies BLOCKER: normalize_log_prefix must be idempotent and strip all
	// trailing colons/spaces in any interleaving (foo:: , foo: : , etc.).
	const cases = [
		{ raw: 'zz::', expect: 'zz' },
		{ raw: 'foo:: ', expect: 'foo' },
	];
	for (const c of cases) {
		const stubNft = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-xnft-'));
		try {
			makeStub(stubNft, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "${c.raw}"
	}
}
EOF
else
	exit 1
fi
`);
			makeStub(stubNft, 'uci', `#!/bin/sh
exit 0
`);
			const env = { ...process.env, PATH: `${stubNft}:${process.env.PATH}` };
			for (const shell of posixShells()) {
				let raw;
				try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
				const res = JSON.parse(raw);
				assert.equal(res.rules[c.expect], c.expect.split('-').join(' '), `[${shell}] nft ${c.raw} -> ${c.expect}`);
				assert.equal(res.rules[c.raw], undefined, `[${shell}] nft buggy key ${c.raw} must not exist`);
				assert.equal((raw.match(new RegExp('"' + c.expect.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '":')) || []).length, 1, `[${shell}] nft raw should have exactly one ${c.expect}`);
			}
		} finally { fs.rmSync(stubNft, { recursive: true, force: true }); }
	}
}

function testEmptyPrefixGuard() {
	// ":::" and variants normalize to empty and must not be added (guard fires)
	// Without idempotent normalize, ":::" -> "::" (non-empty) and junk key emitted.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-empty-'));
	try {
		makeStub(stubDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix ":::"
		log prefix "::"
		log prefix ":"
		log prefix "valid:: "
	}
}
EOF
else
	exit 1
fi
`);
		makeStub(stubDir, 'uci', `#!/bin/sh
exit 0
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		for (const shell of posixShells()) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const res = JSON.parse(raw);
			// catches junk "::" key surviving single-pass normalize
			assert.equal(res.rules['::'], undefined, `[${shell}] empty guard: :: must not exist`);
			assert.equal(res.rules[':'], undefined, `[${shell}] empty guard: : must not exist`);
			assert.equal(res.rules[':::' ], undefined, `[${shell}] empty guard: ::: must not exist`);
			assert.equal(res.rules[''], undefined, `[${shell}] empty key must not exist`);
			assert.equal(res.rules['valid'], 'valid', `[${shell}] valid:: must normalize to valid`);
			// raw must not contain junk keys
			assert.equal((raw.match(/"::":/g) || []).length, 0, `[${shell}] raw must not contain "::"`);
			assert.equal((raw.match(/":::"/g) || []).length, 0, `[${shell}] raw must not contain ":::"`);
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }
}

function testUciStreamMergeAndCollision() {
	// 1. UCI + stream merge: both contribute distinct keys
	// 2. Collision: UCI authoritative name wins over log-prefix (first-wins)
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-ucimix-'));
	try {
		makeStub(stubDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "foo-bar"
		log prefix "nft-only"
	}
}
EOF
else
	exit 1
fi
`);
		makeStub(stubDir, 'uci', `#!/bin/sh
		if [ "$1" = "-q" ] && [ "$2" = "show" ] && [ "$3" = "firewall" ]; then
			echo "firewall.@rule[0].name='foo-bar'"
			echo "firewall.@rule[1].name='uci-only'"
			echo "firewall.allow-ssh=rule"
		elif [ "$1" = "-q" ] && [ "$2" = "get" ] && [ "$3" = "firewall.allow-ssh.name" ]; then
			echo 'Allow-SSH'
		else
			exit 0
fi
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		for (const shell of posixShells()) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const res = JSON.parse(raw);
			// merge: uci-only must be present (catches lost UCI when fragment overwrote)
			assert.equal(res.rules['uci-only'], 'uci-only', `[${shell}] uci+stream merge: uci-only present`);
			assert.equal(res.rules['Allow-SSH'], 'Allow-SSH', `[${shell}] named UCI rule present`);
			// merge: nft-only must be present (catches subshell discard)
			assert.equal(res.rules['nft-only'], 'nft only', `[${shell}] uci+stream merge: nft-only present`);
			// collision: foo-bar from UCI vs nft log prefix foo-bar -> single key (catches naive case "$OUT" *"$key"*)
			const cnt = (raw.match(/"foo-bar":/g) || []).length;
			assert.equal(cnt, 1, `[${shell}] collision foo-bar must appear once, got ${cnt} in ${raw}`);
			// first-wins: UCI value wins over cosmetic nft label
			assert.equal(res.rules['foo-bar'], 'foo-bar', `[${shell}] first-wins UCI must win over nft cosmetic`);
			// also ensure value collision on "see foo" does not false-positive (regression for naive substring check)
			// foo inside value "see foo" must not hide missing key
			assert.equal(res.rules['foo'], undefined, `[${shell}] foo should not exist as key just because value contains foo`);
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }

	// Additional collision via slug: UCI name 'Foo_Bar' -> slug foo-bar collides with nft prefix foo-bar
	const stubDir2 = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-slugcoll-'));
	try {
		makeStub(stubDir2, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 { chain input { log prefix "foo-bar" } }
EOF
else
	exit 1
fi
`);
		makeStub(stubDir2, 'uci', `#!/bin/sh
if [ "$1" = "-q" ] && [ "$2" = "show" ] && [ "$3" = "firewall" ]; then
	echo "firewall.@rule[0].name='Foo_Bar'"
else
	exit 0
fi
`);
		const env = { ...process.env, PATH: `${stubDir2}:${process.env.PATH}` };
		for (const shell of posixShells()) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const cnt = (raw.match(/"foo-bar":/g) || []).length;
			// catches duplicate via slug collision (Foo_Bar slug == foo-bar)
			assert.equal(cnt, 1, `[${shell}] slug collision foo-bar must be 1, got ${cnt} in ${raw}`);
			// ensure Foo_Bar still present as raw UCI key plus deduped slug not duplicated
			const res = JSON.parse(raw);
			assert.equal(res.rules['Foo_Bar'], 'Foo_Bar', `[${shell}] UCI raw Foo_Bar present`);
		}
	} finally { fs.rmSync(stubDir2, { recursive: true, force: true }); }

	// Substring safety: "foo" vs "foobar" must not false-positive (naive *"$key"* would)
	const stubDir3 = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-substr-'));
	try {
		makeStub(stubDir3, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input { log prefix "foobar" }
	chain forward { log prefix "foo" }
}
EOF
else
	exit 1
fi
`);
		makeStub(stubDir3, 'uci', `#!/bin/sh
exit 0
`);
		const env = { ...process.env, PATH: `${stubDir3}:${process.env.PATH}` };
		for (const shell of posixShells()) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const res = JSON.parse(raw);
			// both keys must coexist (catches naive *foo* matching foobar)
			assert.equal(res.rules['foobar'], 'foobar', `[${shell}] foobar present`);
			assert.equal(res.rules['foo'], 'foo', `[${shell}] foo present alongside foobar`);
			assert.equal((raw.match(/"foo":/g) || []).length, 1, `[${shell}] foo raw count 1`);
			assert.equal((raw.match(/"foobar":/g) || []).length, 1, `[${shell}] foobar raw count 1`);
		}
	} finally { fs.rmSync(stubDir3, { recursive: true, force: true }); }
}

function testPollClampLinesContract() {
	// Verify poll_clamp_lines validates non-digit input (was trust-caller before)
	const shells = posixShells();
	for (const shell of shells) {
		function runClamp(val) {
			if (shell === 'busybox') {
				return execFileSync('busybox', ['sh', RPCD, '__poll_clamp', val], { encoding: 'utf8' }).trim();
			}
			return execFileSync(shell, [RPCD, '__poll_clamp', val], { encoding: 'utf8' }).trim();
		}
		try {
			const nonDigit = runClamp('12x');
			assert.equal(nonDigit, '50', `[${shell}] poll_clamp_lines 12x must return 50, got ${nonDigit} (catches trust-caller validation)`);
			const abc = runClamp('abc');
			assert.equal(abc, '50', `[${shell}] poll_clamp_lines abc must return 50`);
			const empty = runClamp('');
			assert.equal(empty, '50', `[${shell}] poll_clamp_lines empty must return 50`);
			// also verify the six digit cases still hold via __poll_clamp (catches regression in length check)
			const v50 = runClamp('0000000500');
			assert.equal(v50, '500', `[${shell}] 0000000500 -> 500`);
			const zero = runClamp('0');
			assert.equal(zero, '50', `[${shell}] 0 -> 50`);
		} catch (e) {
			if (e.code === 'ENOENT') continue;
			throw e;
		}
	}
}

function testNoMktempGracefulDegradation() {
	// Security property: rules map must not write to a predictable path
	// when mktemp is absent. With mktemp missing/failing, the helper must
	// return empty and the backend enrichment is skipped -- but UCI names
	// and backend detection must still return well-formed JSON and no
	// /tmp/fwlive-* file may appear. The old
	//   mktemp ... || mktemp ... || printf '/tmp/fwlive-nft-%s' "$$"
	// fallback would have written through a symlink at that predictable
	// path as root. Assertions below catch:
	//  1. well-formed JSON + backend + uci still present => catch missing
	//     graceful-degradation (method failing or malformed JSON when mktemp
	//     absent).
	//  2. no /tmp/fwlive-* file after call => catch predictable-path write
	//     (the symlink arbitrary-write primitive).
	//  3. nft-derived key absent => catch fallback that still wrote the
	//     ruleset dump to a fixed path instead of skipping enrichment.
	const shells = posixShells();
	// Ubuntu BusyBox ash can be built with standalone applets, so `mktemp`
	// inside `busybox sh` ignores PATH. Skip that shell when the stub
	// cannot actually hide mktemp (dash still covers the helper).
	let busyboxHonorsPath = true;
	try {
		const probe = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-mkprobe-'));
		try {
			makeStub(probe, 'mktemp', '#!/bin/sh\nexit 127\n');
			execFileSync('busybox', ['sh', '-c', 'mktemp /tmp/fwlive-probe.XXXXXX'], {
				env: { ...process.env, PATH: `${probe}:${process.env.PATH}` },
				stdio: 'ignore',
			});
			busyboxHonorsPath = false;
		} catch (e) {
			if (e.code === 'ENOENT') busyboxHonorsPath = false;
		} finally {
			fs.rmSync(probe, { recursive: true, force: true });
			try { execFileSync('sh', ['-c', 'rm -f /tmp/fwlive-probe.* 2>/dev/null; true']); } catch {}
		}
	} catch { /* probe setup failed; try busybox anyway */ }
	const runnable = shells.filter((s) => s !== 'busybox' || busyboxHonorsPath);
	assert.ok(runnable.length > 0, 'need a PATH-honouring POSIX shell for mktemp degradation');
	let ran = 0;
	for (const shell of runnable) {
		const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-nomktemp-'));
		try {
			// nft would emit a prefix that would appear if temp file were used
			makeStub(stubDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "should-not-appear"
	}
}
EOF
else
	exit 1
fi
`);
			makeStub(stubDir, 'uci', `#!/bin/sh
if [ "$1" = "-q" ] && [ "$2" = "show" ] && [ "$3" = "firewall" ]; then
	echo "firewall.@rule[0].name='uci-keep'"
	echo "firewall.@rule[1].name='another-rule'"
else
	exit 0
fi
`);
			// shadow mktemp with a failing stub so both helper attempts fail
			// (simulates mktemp absent from PATH; real mktemp still on PATH
			// but shadowed at the front, so helper's  mktemp ... || mktemp
			// both hit this failing stub)
			makeStub(stubDir, 'mktemp', `#!/bin/sh
echo "mktemp shadow: absent" >&2
exit 127
`);
			const listTemps = () => {
				try {
					return execFileSync('sh', ['-c',
						'ls -1 /tmp/fwlive-nft.* /tmp/fwlive-ipt.* /tmp/fwlive-ip6t.* 2>/dev/null || true'],
					{ encoding: 'utf8' }).trim().split('\n').filter(Boolean);
				} catch { return []; }
			};
			const before = new Set(listTemps());
			const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
			let raw;
			try {
				raw = runWithShell(shell, env);
			} catch (e) {
				if (e.code === 'ENOENT') continue;
				throw e;
			}
			ran++;
			// well-formed JSON and backend + UCI names must still be present
			let res;
			try { res = JSON.parse(raw); } catch (e) { throw new Error(`[${shell}] JSON malformed when mktemp absent: ${raw}: ${e.message}`); }
			assert.equal(res.backend, 'nft', `[${shell}] backend should still be nft when mktemp absent`);
			assert.equal(res.error, 'mktemp_failed', `[${shell}] mktemp skip must surface error (#231)`);
			assert.equal(res.rules['uci-keep'], 'uci-keep', `[${shell}] uci-keep must survive mktemp absent (graceful degradation)`);
			assert.equal(res.rules['another-rule'], 'another-rule', `[${shell}] another-rule must survive`);
			// nft-derived enrichment must be skipped (no temp file to parse)
			assert.equal(res.rules['should-not-appear'], undefined, `[${shell}] nft enrichment must be skipped when mktemp absent, not written via fixed path`);
			// must not have created any NEW nft/ipt/ip6t temp file (do not rm peers)
			const created = listTemps().filter((f) => !before.has(f));
			assert.equal(created.length, 0, `[${shell}] no new /tmp/fwlive-{nft,ipt,ip6t}* when mktemp absent, got: ${created.join(' ')}`);
			// raw JSON must not contain the nft key at all
			assert.equal((raw.match(/"should-not-appear"/g) || []).length, 0, `[${shell}] raw must not contain should-not-appear`);
		} finally {
			fs.rmSync(stubDir, { recursive: true, force: true });
		}
	}
	assert.ok(ran > 0, 'mktemp degradation must run under at least one POSIX shell');
}

function testTsvAwkFailureKeepsStructuredReply() {
	// #664: nft_dump_fields awk under set -eu must not abort call rules.
	// A failing awk is tsv_failed + UCI-only rules, never empty stdout.
	const nftDump = `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "should-not-appear" comment "!fw4: From-nft"
	}
}
EOF
else
	exit 1
fi
`;
	const uciDump = `#!/bin/sh
if [ "$1" = "-q" ] && [ "$2" = "show" ] && [ "$3" = "firewall" ]; then
	echo "firewall.@rule[0].name='uci-keep'"
else
	exit 0
fi
`;
	let ran = 0;
	const realAwk = hostCommand('awk');
	for (const shell of pathHonouringShells('awk')) {
		const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-tsv-awk-'));
		try {
			makeStub(stubDir, 'nft', nftDump);
			makeStub(stubDir, 'uci', uciDump);
			makeStub(stubDir, 'awk', `#!/bin/sh
for arg in "$@"; do
	case "$arg" in
		*'quoted_at'*)
			echo "awk stub fail" >&2
			exit 7
			;;
	esac
done
exec "${realAwk}" "$@"
`);
			const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
			let raw;
			try {
				raw = runWithShell(shell, env);
			} catch (e) {
				if (e.code === 'ENOENT') continue;
				throw new Error(`[${shell}] call rules aborted on awk failure: ${e.stdout || ''} ${e.stderr || ''} ${e.message}`);
			}
			ran++;
			let res;
			try {
				res = JSON.parse(raw);
			} catch (e) {
				throw new Error(`[${shell}] JSON malformed when awk fails: ${raw}: ${e.message}`);
			}
			assert.equal(res.backend, 'nft', `[${shell}] backend stays nft when TSV awk fails`);
			assert.equal(res.error, 'tsv_failed', `[${shell}] awk failure must surface tsv_failed`);
			assert.equal(res.rules['uci-keep'], 'uci-keep', `[${shell}] UCI names survive TSV awk failure`);
			assert.equal(res.rules['should-not-appear'], undefined, `[${shell}] nft enrichment must be skipped when awk fails`);
			assert.equal((raw.match(/"should-not-appear"/g) || []).length, 0,
				`[${shell}] raw must not contain nft prefix after awk failure`);
		} finally {
			fs.rmSync(stubDir, { recursive: true, force: true });
		}
	}
	assert.ok(ran > 0, 'tsv awk degradation must run under at least one POSIX shell');
}


function testGlobMetacharDedup() {
	// BLOCKER r5: quoted+escaped dedup missed glob keys (foo*, a*b[?c). Must be single key in raw JSON.
	// Also verifies literal match: a*b[?c must not wildcard-match aXYZbYc.
	const cases = [
		{ raw: 'foo*', label: 'FooStar' },
		{ raw: 'a*b[?c', label: 'GlobKey' },
	];
	for (const c of cases) {
		const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-glob-'));
		try {
			makeStub(stubDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "${c.raw}" comment "!fw4: ${c.label}"
		log prefix "${c.raw}"
	}
}
EOF
else
	exit 1
fi
`);
			makeStub(stubDir, 'uci', `#!/bin/sh
exit 0
`);
			const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
			for (const shell of posixShells()) {
				let raw;
				try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
				const res = JSON.parse(raw);
				// dedup: glob key must appear once in raw JSON (catches quoted+escaped miss)
				const esc = c.raw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
				const cnt = (raw.match(new RegExp('"' + esc + '":', 'g')) || []).length;
				assert.equal(cnt, 1, `[${shell}] glob dedup ${c.raw} must appear once, got ${cnt} in ${raw}`);
				assert.equal(res.rules[c.raw], c.label, `[${shell}] glob key ${c.raw} present`);
			}
		} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }
	}

	// Literal wildcard safety: a*b[?c must coexist with aXYZbYc (not wildcard-matched)
	const stubDir2 = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-glob2-'));
	try {
		makeStub(stubDir2, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "a*b[?c"
		log prefix "aXYZbYc"
	}
}
EOF
else
	exit 1
fi
`);
		makeStub(stubDir2, 'uci', `#!/bin/sh
exit 0
`);
		const env = { ...process.env, PATH: `${stubDir2}:${process.env.PATH}` };
		for (const shell of posixShells()) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const res = JSON.parse(raw);
			assert.equal(res.rules['a*b[?c'], 'a*b[?c'.split('-').join(' '), `[${shell}] literal glob key a*b[?c present`);
			// note: cosmetic normalizes '-' -> ' ', but * [ ? stay; check value is cosmetic
			assert.equal(res.rules['aXYZbYc'], 'aXYZbYc', `[${shell}] aXYZbYc must coexist with a*b[?c (literal, not wildcard)`);
			assert.equal((raw.match(/"a\*b\[\?c":/g) || []).length, 1, `[${shell}] raw a*b[?c count 1`);
			assert.equal((raw.match(/"aXYZbYc":/g) || []).length, 1, `[${shell}] raw aXYZbYc count 1`);
		}
	} finally { fs.rmSync(stubDir2, { recursive: true, force: true }); }
}

function testTmpDirSticky() {
	execFileSync(RPCD, ['__tmp_dir_ok']);
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-tmpok-'));
	const link = `${dir}-link`;
	try {
		fs.chmodSync(dir, 0o777);
		let failed = false;
		try {
			execFileSync(RPCD, ['__tmp_dir_ok', dir], { stdio: 'ignore' });
		} catch (e) {
			failed = e.status !== 0;
		}
		assert.equal(failed, true, '0777 without sticky must fail');

		fs.chmodSync(dir, 0o1777);
		execFileSync(RPCD, ['__tmp_dir_ok', dir]);

		fs.symlinkSync(dir, link);
		failed = false;
		try {
			execFileSync(RPCD, ['__tmp_dir_ok', link], { stdio: 'ignore' });
		} catch (e) {
			failed = e.status !== 0;
		}
		assert.equal(failed, true, 'symlink dump dir must fail');
	} finally {
		try { fs.unlinkSync(link); } catch { /* absent */ }
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

function testTmpDirStickyBusybox() {
	if (!posixShells().includes('busybox')) return;
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-busybox-tmpok-'));
	const link = dir + '-link';
	try {
		let failed = false;
		fs.chmodSync(dir, 0o777);
		try {
			runRpcd('busybox', ['__tmp_dir_ok', dir], { stdio: 'ignore' });
		} catch (e) {
			failed = e.status !== 0;
		}
		assert.equal(failed, true, 'busybox 0777 without sticky must fail');
		fs.chmodSync(dir, 0o1777);
		runRpcd('busybox', ['__tmp_dir_ok', dir]);
		fs.symlinkSync(dir, link);
		failed = false;
		try {
			runRpcd('busybox', ['__tmp_dir_ok', link], { stdio: 'ignore' });
		} catch (e) {
			failed = e.status !== 0;
		}
		assert.equal(failed, true, 'busybox symlink dump dir must fail');
	} finally {
		try { fs.unlinkSync(link); } catch { /* absent */ }
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

function testUciWhitespaceNames() {
	// #226: "My Rule" must not word-split into My/Rule junk keys, and must
	// not shadow a real rule named Rule. Space-containing names are skipped
	// (parseRuleHint cannot match them).
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-ws-'));
	try {
		makeStub(stubDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
	exit 1
fi
`);
		makeStub(stubDir, 'uci', `#!/bin/sh
if [ "$1" = "-q" ] && [ "$2" = "show" ] && [ "$3" = "firewall" ]; then
	echo "firewall.@rule[0].name='My Rule'"
	echo "firewall.@rule[1].name='Rule'"
	echo "firewall.@rule[2].name='Allow-SSH'"
else
	exit 0
fi
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		for (const shell of posixShells()) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const res = JSON.parse(raw);
			assert.equal(res.rules['My'], undefined, `[${shell}] fragment My must not exist`);
			assert.equal(res.rules['my'], undefined, `[${shell}] fragment my must not exist`);
			assert.equal(res.rules['My Rule'], undefined, `[${shell}] space-containing name is skipped`);
			assert.equal(res.rules['Rule'], 'Rule', `[${shell}] real Rule must not be shadowed`);
			assert.equal(res.rules['rule'], 'Rule', `[${shell}] Rule slug present`);
			assert.equal(res.rules['Allow-SSH'], 'Allow-SSH', `[${shell}] Allow-SSH kept`);
			assert.equal((raw.match(/"My":/g) || []).length, 0, `[${shell}] raw must not contain My`);
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }
}

function testUciStyleNameCharset() {
	// #615: is_uci_style_name admits non-empty [A-Za-z0-9_-]+ on the
	// whole string. First-char-ok / later-char-illegal names must not
	// become map keys (the old [!class]* glob accepted them).
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-uci-cs-'));
	try {
		makeStub(stubDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "later-dollar" comment "!fw4: rule$x"
		log prefix "later-semi" comment "!fw4: rule;id"
		log prefix "lead-hyphen" comment "!fw4: -lead"
		log prefix "ok-rule" comment "!fw4: Rule"
	}
}
EOF
else
	exit 1
fi
`);
		makeStub(stubDir, 'uci', `#!/bin/sh
if [ "$1" = "-q" ] && [ "$2" = "show" ] && [ "$3" = "firewall" ]; then
	cat <<'UCI'
firewall.@rule[0].name='Rule'
firewall.@rule[1].name='My Rule'
firewall.@rule[2].name='rule$x'
firewall.@rule[3].name='rule;id'
firewall.@rule[4].name='-lead'
firewall.@rule[5].name=''
UCI
else
	exit 0
fi
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		for (const shell of posixShells()) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const res = JSON.parse(raw);
			assert.equal(res.rules['Rule'], 'Rule', `[${shell}] Rule is in the admitted charset`);
			assert.equal(res.rules['My Rule'], undefined, `[${shell}] space-containing name is skipped`);
			assert.equal(res.rules['rule$x'], undefined, `[${shell}] later-char $ must not be a map key`);
			assert.equal(res.rules['rule;id'], undefined, `[${shell}] later-char ; must not be a map key`);
			assert.equal(res.rules['-lead'], '-lead', `[${shell}] leading hyphen is in the charset`);
			assert.equal(res.rules[''], undefined, `[${shell}] empty name is skipped`);
			assert.equal(res.rules['later-dollar'], 'later dollar',
				`[${shell}] !fw4: rule$x must not label; got ${JSON.stringify(res.rules['later-dollar'])}`);
			assert.equal(res.rules['later-semi'], 'later semi',
				`[${shell}] !fw4: rule;id must not label; got ${JSON.stringify(res.rules['later-semi'])}`);
			assert.equal(res.rules['lead-hyphen'], '-lead', `[${shell}] !fw4: -lead is an admitted suffix`);
			assert.equal(res.rules['ok-rule'], 'Rule', `[${shell}] !fw4: Rule is an admitted suffix`);
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }
}

function testResolveNslookup() {
	const bindOut = 'Server: 127.0.0.1\nAddress: 127.0.0.1:53\n\n1.2.0.192.in-addr.arpa\tname = ptr.example.';
	let got = execFileSync(RPCD, ['__parse_nslookup', bindOut], { encoding: 'utf8' }).trim();
	assert.equal(got, 'ptr.example', 'bind-style name = host');

	const bbOut = 'Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\nAddress 1: 192.0.2.1 ptr.example.';
	got = execFileSync(RPCD, ['__parse_nslookup', bbOut], { encoding: 'utf8' }).trim();
	assert.equal(got, 'ptr.example', 'busybox Address N: ip host');

	const miniOut = 'Server: 192.168.1.1\nAddress 1: 192.168.1.1 router.lan\n\nName: 8.8.8.8\nAddress 1: 8.8.8.8 dns.google';
	got = execFileSync(RPCD, ['__parse_nslookup', miniOut], { encoding: 'utf8' }).trim();
	assert.equal(got, 'dns.google', 'mini nslookup must skip resolver Address N');

	let emptyStatus = 0;
	try {
		got = execFileSync(RPCD, ['__parse_nslookup', 'Server: 127.0.0.1\nAddress: 127.0.0.1:53'], { encoding: 'utf8' }).trim();
	} catch (e) {
		emptyStatus = e.status;
		got = String(e.stdout || '').trim();
	}
	assert.equal(got, '', 'server-only is not a name');
	assert.equal(emptyStatus, 1, 'empty parse must fail');

	function parseNslookup(input) {
		try {
			return {
				got: execFileSync(RPCD, ['__parse_nslookup', input], { encoding: 'utf8' }).trim(),
				status: 0,
			};
		} catch (e) {
			return { got: String(e.stdout || '').trim(), status: e.status };
		}
	}
	let parsed = parseNslookup('hostname = evil.example.');
	assert.equal(parsed.got, '', 'hostname = is not a PTR name field');
	assert.equal(parsed.status, 1, 'hostname = parse must fail');
	parsed = parseNslookup('domain name = other.example.');
	assert.equal(parsed.got, '', 'domain name = is not a PTR name field');
	assert.equal(parsed.status, 1, 'domain name = parse must fail');
	parsed = parseNslookup('domain  name = two.example.');
	assert.equal(parsed.got, '', 'domain  name = (repeated space) is not a PTR name field');
	assert.equal(parsed.status, 1, 'domain  name = parse must fail');
	parsed = parseNslookup('domain\t name = tab.example.');
	assert.equal(parsed.got, '', 'domain<tab> name = is not a PTR name field');
	assert.equal(parsed.status, 1, 'domain tab-space name = parse must fail');
	parsed = parseNslookup('8.8.8.8.in-addr.arpa\tname = dns.google.');
	assert.equal(parsed.got, 'dns.google', 'bind-style name = still parses');
	assert.equal(parsed.status, 0, 'bind-style name = must succeed');
	parsed = parseNslookup('name = dns.google. hostname = evil.example.');
	assert.equal(parsed.got, 'dns.google', 'standalone name = must beat hostname =');
	assert.equal(parsed.status, 0, 'standalone name = must succeed');

	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-ns-'));
	try {
		makeStub(stubDir, 'nslookup', `#!/bin/sh
echo "marker-nslookup $1" >> "${stubDir}/called"
cat <<'EOF'
Server: 127.0.0.1
Address: 127.0.0.1:53

1.2.0.192.in-addr.arpa	name = ptr.example.
EOF
`);
		makeStub(stubDir, 'getent', `#!/bin/sh
echo "getent-must-not-run" >> "${stubDir}/called"
exit 1
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		const shells = posixShells().filter((s) => s !== 'busybox' || busyboxHonorsPath('nslookup'));
		assert.ok(shells.length > 0, 'need a PATH-honouring POSIX shell for nslookup stub');
		for (const shell of shells) {
			const out = runRpcd(shell, ['__resolve_one', '192.0.2.1'], { encoding: 'utf8', env }).trim();
			assert.equal(out, 'ptr.example', `[${shell}] resolve_hostname uses nslookup`);
			const called = fs.readFileSync(path.join(stubDir, 'called'), 'utf8');
			assert.ok(called.includes('marker-nslookup 192.0.2.1'), `[${shell}] nslookup saw the validated IP`);
			assert.ok(!called.includes('getent-must-not-run'), `[${shell}] getent must not run`);

			let rejected = false;
			try {
				runRpcd(shell, ['__resolve_one', 'dead.beef.cafe.baad'], {
					encoding: 'utf8', env, stdio: ['ignore', 'pipe', 'pipe']
				});
			} catch (e) {
				rejected = e.status !== 0;
			}
			assert.equal(rejected, true, `[${shell}] hostname-shaped token must not reach nslookup`);
			const called2 = fs.readFileSync(path.join(stubDir, 'called'), 'utf8');
			assert.ok(!called2.includes('dead.beef'), `[${shell}] invalid token must not reach nslookup`);
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }

	const noNs = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-nons-'));
	try {
		makeStub(noNs, 'true', '#!/bin/sh\nexit 0\n');
		// dirname is needed to source logging.sh; keep nslookup off PATH.
		makeStub(noNs, 'dirname', '#!/bin/sh\n/usr/bin/dirname "$@"\n');
		const env = { ...process.env, PATH: noNs };
		const shells = posixShells().filter((s) => s !== 'busybox' || busyboxHonorsPath('nslookup'));
		assert.ok(shells.length > 0, 'need a PATH-honouring POSIX shell for no_resolver probe');
		for (const shell of shells) {
			const raw = runRpcd(shell, ['call', 'resolve'], {
				encoding: 'utf8', env, input: '{"addresses":["192.0.2.1"]}'
			});
			const res = JSON.parse(raw);
			assert.equal(res.error, 'no_resolver', `[${shell}] missing nslookup must surface error`);
			assert.deepEqual(res.names, {}, `[${shell}] names empty when resolver missing`);
		}
	} finally { fs.rmSync(noNs, { recursive: true, force: true }); }
}

function testFw4LabeledBeatsCosmetic() {
	// Unlabeled shared-pfx then !fw4: Authoritative-Name must prefer the label (#230).
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-fw4pref-'));
	try {
		makeStub(stubDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
		log prefix "shared-pfx"
		log prefix "shared-pfx" comment "!fw4: Authoritative-Name"
	}
}
EOF
else
	exit 1
fi
`);
		makeStub(stubDir, 'uci', `#!/bin/sh
exit 0
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		for (const shell of posixShells()) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const res = JSON.parse(raw);
			assert.equal(res.rules['shared-pfx'], 'Authoritative-Name',
				`[${shell}] !fw4: must beat earlier cosmetic, got ${JSON.stringify(res.rules['shared-pfx'])}`);
			assert.notEqual(res.rules['shared-pfx'], 'shared pfx',
				`[${shell}] cosmetic must not win`);
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }
}


function testRulesMapKeyBound() {
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-bound-'));
	try {
		const lines = [];
		for (let i = 0; i < 600; i++)
			lines.push(`\t\tlog prefix "pfx-${i}"`);
		makeStub(stubDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 {
	chain input {
${lines.join('\n')}
	}
}
EOF
else
	exit 1
fi
`);
		makeStub(stubDir, 'uci', '#!/bin/sh\nexit 0\n');
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		for (const shell of posixShells()) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const res = JSON.parse(raw);
			assert.equal(res.error, 'rules_truncated', `[${shell}] oversized map must set rules_truncated`);
			const keys = Object.keys(res.rules || {});
			assert.ok(keys.length <= 512, `[${shell}] keys ${keys.length} must be <= 512`);
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }
}

function testRulesMapByteBound() {
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-byte-bound-'));
	const hugeA = 'A'.repeat(30000) + 'a';
	const hugeB = 'B'.repeat(30000) + 'b';
	try {
		const nft = [
			'#!/bin/sh',
			'if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then',
			"cat <<'EOF'",
			'table inet fw4 {',
			'\tchain input {',
			'\t\tlog prefix "' + hugeA + '"',
			'\t\tlog prefix "' + hugeB + '"',
			'\t}',
			'}',
			'EOF',
			'else',
			'\texit 1',
			'fi',
			''
		].join('\n');
		makeStub(stubDir, 'nft', nft);
		makeStub(stubDir, 'uci', '#!/bin/sh\nexit 0\n');
		const env = {
			...process.env,
			PATH: stubDir + ':' + process.env.PATH
		};
		for (const shell of posixShells()) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) {
				if (e.code === 'ENOENT') continue;
				throw e;
			}
			const res = JSON.parse(raw);
			assert.equal(res.error, 'rules_truncated', '[' + shell + '] byte cap must set rules_truncated');
			assert.equal(res.rules[hugeA], hugeA, '[' + shell + '] first ASCII huge key should fit');
			assert.equal(res.rules[hugeB], undefined, '[' + shell + '] second huge key must be capped');
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }
}

function installNslookupStub(stubDir) {
	makeStub(stubDir, 'nslookup', `#!/bin/sh
echo "marker-nslookup $1" >> "${stubDir}/called"
cat <<'EOF'
Server: 127.0.0.1
Address: 127.0.0.1:53

1.2.0.192.in-addr.arpa	name = ptr.example.
EOF
`);
}

function testBusyboxPathShadowNslookup() {
	// Production: resolve_hostname → run_with_timeout nslookup (rpcd/fwlive).
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-bbshadow-ns-'));
	try {
		installNslookupStub(stubDir);
		const env = stubPathEnv(stubDir);
		for (const shell of pathHonouringShells('nslookup')) {
			resetCalled(stubDir);
			const out = runRpcd(shell, ['__resolve_one', '192.0.2.1'], { encoding: 'utf8', env }).trim();
			assert.equal(out, 'ptr.example', `[${shell}] PATH-first nslookup still parses`);
			assert.ok(readCalled(stubDir).includes('marker-nslookup 192.0.2.1'),
				`[${shell}] nslookup stub ran`);
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }
}

function testBusyboxPathShadowTimeout() {
	// Production: run_with_timeout wraps nft list ruleset on the rules path.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-bbshadow-to-'));
	try {
		makeStub(stubDir, 'timeout', `#!/bin/sh
echo "marker-timeout" >> "${stubDir}/called"
shift
exec "$@"
`);
		installNftUciStubs(stubDir);
		const env = stubPathEnv(stubDir);
		for (const shell of pathHonouringShells('timeout')) {
			resetCalled(stubDir);
			assertNftSshRules(shell, runWithShell(shell, env));
			assert.ok(readCalled(stubDir).includes('marker-timeout'),
				`[${shell}] timeout stub ran`);
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }
}

function testBusyboxPathShadowJsonfilter() {
	// Production: fwlive-log-filter.sh pipes poll JSON through jsonfilter -e '@.log[*]'.
	// rules never calls jsonfilter — drive the filter, not the rules map.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-bbshadow-jf-'));
	try {
		makeStub(stubDir, 'jsonfilter', `#!/bin/sh
echo "marker-jsonfilter $*" >> "${stubDir}/called"
printf '%s\\n' '{"msg":"IN=wan OUT= SRC=203.0.113.77 DST=192.0.2.77 PROTO=TCP","id":"path-shadow-jsonfilter"}'
`);
		const env = stubPathEnv(stubDir);
		const payload = JSON.stringify({
			log: [{ msg: 'not-a-firewall-line', id: 'host-jsonfilter-must-not-win' }]
		});
		for (const shell of pathHonouringShells('jsonfilter')) {
			resetCalled(stubDir);
			const raw = runPosixFile(shell, FILTER_SH, { encoding: 'utf8', env, input: payload });
			assert.ok(readCalled(stubDir).includes('marker-jsonfilter'),
				`[${shell}] jsonfilter stub ran`);
			assert.ok(raw.includes('path-shadow-jsonfilter'),
				`[${shell}] filter used PATH-first jsonfilter output`);
			assert.ok(!raw.includes('host-jsonfilter-must-not-win'),
				`[${shell}] host jsonfilter must not win`);
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }
}

function testBusyboxPathShadowStat() {
	// Production dropped `stat -c` from wan_log_lock_dir_safe (#232).
	// Lock-dir safety is `[ -O ]` + `find -prune -perm`. PATH-shadow find.
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-bbshadow-stat-'));
	const safeDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-bbshadow-lockdir-'));
	try {
		fs.chmodSync(safeDir, 0o755);
		const realFind = hostCommand('find');
		makeStub(stubDir, 'find', `#!/bin/sh
echo "marker-find $*" >> "${stubDir}/called"
exec "${realFind}" "$@"
`);
		const env = stubPathEnv(stubDir);
		const script = `. "${LOGGING_SH}" && wan_log_lock_dir_safe "${safeDir}"`;
		for (const shell of pathHonouringShells('find')) {
			resetCalled(stubDir);
			runPosixC(shell, script, { encoding: 'utf8', env });
			const called = readCalled(stubDir);
			assert.ok(called.includes('marker-find'),
				`[${shell}] find stub ran (stat replacement #232)`);
			assert.ok(called.includes(safeDir), `[${shell}] find saw the lock dir`);
		}
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
		fs.rmSync(safeDir, { recursive: true, force: true });
	}
}

function testBusyboxPathShadowGetent() {
	// getent is not on the production resolve path (#218/#228).
	// PATH-shadow coverage is testBusyboxPathShadowNslookup (the replacement).
	// A "must not run" stub is not PATH-shadow coverage — do not add one.
	const src = fs.readFileSync(RPCD, 'utf8');
	assert.equal(src.includes('getent'), false,
		'rpcd/fwlive must not call getent; resolve uses nslookup (#218/#228)');
}


function run() {
	testProductionNft();
	testNftPrefixNormalization();
	testDuplicateKeys();
	testIdempotentNormalization();
	testEmptyPrefixGuard();
	testUciStreamMergeAndCollision();
	testFw4LabeledBeatsCosmetic();
	testPollClampLinesContract();
	testNoMktempGracefulDegradation();
	testTsvAwkFailureKeepsStructuredReply();
	testRulesMapKeyBound();
	testRulesMapByteBound();
	testGlobMetacharDedup();
	testTmpDirSticky();
	testTmpDirStickyBusybox();
	testUciWhitespaceNames();
	testUciStyleNameCharset();
	testResolveNslookup();
	testBusyboxPathShadowNslookup();
	testBusyboxPathShadowTimeout();
	testBusyboxPathShadowJsonfilter();
	testBusyboxPathShadowStat();
	testBusyboxPathShadowGetent();
	console.log('fwlive rules map tests passed');
}

run();

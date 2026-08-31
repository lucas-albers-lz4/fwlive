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
const FIXTURE = path.join(__dirname, 'fixtures', 'iptables-save.sample');
const RULESMAP = '/tmp/rulesmap';
const RULESMAP_LOCK = '/tmp/fwlive-rulesmap-test.lock';

function withFileLock(lockPath, fn) {
	// mkdir is atomic; busy-wait with 50ms sleep. 5s timeout prevents hung CI.
	const deadline = Date.now() + 5000;
	while (true) {
		try {
			fs.mkdirSync(lockPath);
			break;
		} catch (e) {
			if (e.code !== 'EEXIST') throw e;
			if (Date.now() > deadline) throw new Error('lock timeout ' + lockPath);
			try { execFileSync('sleep', ['0.05']); } catch {}
		}
	}
	try {
		return fn();
	} finally {
		try { fs.rmdirSync(lockPath); } catch {}
	}
}

function runRedirectPath() {
	// Production pins RULESMAP_IPTABLES_FILE to /tmp/rulesmap for security
	// (no arbitrary argv path). This test must use the fixed path but
	// serialize concurrent invocations via a mkdir lock to avoid races.
	withFileLock(RULESMAP_LOCK, () => {
		fs.copyFileSync(FIXTURE, RULESMAP);
		const raw = execFileSync(RPCD, ['__rulesmap_iptables'], { encoding: 'utf8' });
		const res = JSON.parse(raw);
		assert.equal(res.backend, 'iptables');
		assert.equal(res.rules['fwlive-ping'], 'fwlive-ping');
		assert.equal(res.rules['allow-dns'], 'Allow-DNS');
		// Fixed path only: argv fixture path must not be readable when /tmp/rulesmap is gone.
		fs.unlinkSync(RULESMAP);
		let failed = false;
		try {
			execFileSync(RPCD, ['__rulesmap_iptables', FIXTURE], {
				encoding: 'utf8',
				stdio: ['ignore', 'pipe', 'pipe'],
			});
		} catch (e) {
			failed = e.status !== 0;
		}
		assert.equal(failed, true, 'arbitrary argv path must not be accepted');
	});
}

function makeStub(dir, name, content) {
	const p = path.join(dir, name);
	fs.writeFileSync(p, content, { mode: 0o755 });
}

function runWithShell(shell, env) {
	// shell is 'dash' or 'busybox' (busybox needs 'sh' arg)
	if (shell === 'busybox') {
		return execFileSync('busybox', ['sh', RPCD, 'call', 'rules'], {
			encoding: 'utf8',
			env,
		});
	}
	return execFileSync(shell, [RPCD, 'call', 'rules'], {
		encoding: 'utf8',
		env,
	});
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
		const shells = ['dash', 'busybox'];
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
		const shells = ['dash', 'busybox'];
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

function testProductionIptables() {
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-ipt-'));
	try {
		makeStub(stubDir, 'iptables-save', `#!/bin/sh
cat <<'EOF'
-A INPUT -m comment --comment "Allow-SSH" -j LOG --log-prefix "fwlive-ssh "
-A FORWARD -m comment --comment "Allow-DNS" -j LOG --log-prefix "allow-dns "
EOF
`);
		makeStub(stubDir, 'uci', `#!/bin/sh
exit 0
`);
		// Ensure no nft on PATH for this test: shadow with failing stub
		makeStub(stubDir, 'nft', `#!/bin/sh
exit 1
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		const shells = ['dash', 'busybox'];
		for (const shell of shells) {
			let raw;
			try {
				raw = runWithShell(shell, env);
			} catch (e) {
				if (e.code === 'ENOENT') continue;
				throw e;
			}
			const res = JSON.parse(raw);
			assert.equal(res.backend, 'iptables', `[${shell}] backend should be iptables`);
			// iptables log-prefix must reach OUT (catches pipeline-subshell or missing normalize)
			assert.equal(res.rules['fwlive-ssh'], 'Allow-SSH', `[${shell}] iptables fwlive-ssh`);
			assert.equal(res.rules['allow-dns'], 'Allow-DNS', `[${shell}] iptables allow-dns slug or raw`);
			// raw check: no trailing-space key (catches nft-only normalize)
			assert.equal((raw.match(/"fwlive-ssh "/g) || []).length, 0, `[${shell}] raw must not contain trailing-space key`);
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
		const shells = ['dash', 'busybox'];
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
	// Also test iptables duplicate via stub (prefix normalized, so trailing space stripped still dup)
	const stubDir2 = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-dup2-'));
	try {
		makeStub(stubDir2, 'iptables-save', `#!/bin/sh
cat <<'EOF'
-A INPUT -j LOG --log-prefix "fwlive-wan"
EOF
`);
		makeStub(stubDir2, 'nft', `#!/bin/sh
exit 1
`);
		makeStub(stubDir2, 'uci', `#!/bin/sh
exit 0
`);
		const env = { ...process.env, PATH: `${stubDir2}:${process.env.PATH}` };
		const shells = ['dash', 'busybox'];
		for (const shell of shells) {
			let raw;
			try {
				raw = runWithShell(shell, env);
			} catch (e) {
				if (e.code === 'ENOENT') continue;
				throw e;
			}
			const count = (raw.match(/"fwlive-wan":/g) || []).length;
			assert.equal(count, 1, `[${shell}] iptables duplicate key should be 1, got ${count} in ${raw}`);
		}
	} finally {
		fs.rmSync(stubDir2, { recursive: true, force: true });
	}
}

// --- New tests for R3 findings ---

function testIdempotentNormalizationCrossBackend() {
	// Verifies BLOCKER: normalize_log_prefix must be idempotent and strip all
	// trailing colons/spaces in any interleaving (foo:: , foo: : , etc.)
	// and nft vs iptables must emit identical keys.
	const cases = [
		{ raw: 'zz::', expect: 'zz' },
		{ raw: 'foo:: ', expect: 'foo' },
	];
	for (const c of cases) {
		// nft
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
			for (const shell of ['dash', 'busybox']) {
				let raw;
				try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
				const res = JSON.parse(raw);
				// nft must emit normalized key (catches single-colon strip); raw must not contain buggy key
				assert.equal(res.rules[c.expect], c.expect.split('-').join(' '), `[${shell}] nft ${c.raw} -> ${c.expect}`);
				assert.equal(res.rules[c.raw], undefined, `[${shell}] nft buggy key ${c.raw} must not exist`);
				assert.equal((raw.match(new RegExp('"' + c.expect.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '":')) || []).length, 1, `[${shell}] nft raw should have exactly one ${c.expect}`);
			}
		} finally { fs.rmSync(stubNft, { recursive: true, force: true }); }

		// iptables
		const stubIpt = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-xipt-'));
		try {
			makeStub(stubIpt, 'iptables-save', `#!/bin/sh
cat <<'EOF'
-A INPUT -j LOG --log-prefix "${c.raw}"
EOF
`);
			makeStub(stubIpt, 'nft', `#!/bin/sh
exit 1
`);
			makeStub(stubIpt, 'uci', `#!/bin/sh
exit 0
`);
			const env = { ...process.env, PATH: `${stubIpt}:${process.env.PATH}` };
			for (const shell of ['dash', 'busybox']) {
				let raw;
				try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
				const res = JSON.parse(raw);
				assert.equal(res.rules[c.expect], c.expect.split('-').join(' '), `[${shell}] iptables ${c.raw} -> ${c.expect}`);
				assert.equal(res.rules[c.raw], undefined, `[${shell}] iptables buggy key ${c.raw} must not exist`);
			}
		} finally { fs.rmSync(stubIpt, { recursive: true, force: true }); }
	}

	// Cross-backend identical key check for zz:: and foo::  (catches double-normalization drift)
	const nftDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-cross-nft-'));
	const iptDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-cross-ipt-'));
	try {
		makeStub(nftDir, 'nft', `#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then
cat <<'EOF'
table inet fw4 { chain input { log prefix "zz::" } }
EOF
else
	exit 1
fi
`);
		makeStub(nftDir, 'uci', `#!/bin/sh
exit 0
`);
		makeStub(iptDir, 'iptables-save', `#!/bin/sh
cat <<'EOF'
-A INPUT -j LOG --log-prefix "zz::"
EOF
`);
		makeStub(iptDir, 'nft', `#!/bin/sh
exit 1
`);
		makeStub(iptDir, 'uci', `#!/bin/sh
exit 0
`);
		for (const shell of ['dash', 'busybox']) {
			let rawNft, rawIpt;
			try { rawNft = runWithShell(shell, { ...process.env, PATH: `${nftDir}:${process.env.PATH}` }); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			try { rawIpt = runWithShell(shell, { ...process.env, PATH: `${iptDir}:${process.env.PATH}` }); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const n = JSON.parse(rawNft);
			const i = JSON.parse(rawIpt);
			// identical key on both backends (catches nft-once vs iptables-twice drift)
			assert.equal(n.rules['zz'], 'zz', `[${shell}] nft zz`);
			assert.equal(i.rules['zz'], 'zz', `[${shell}] iptables zz`);
			assert.equal(JSON.stringify(n.rules['zz']), JSON.stringify(i.rules['zz']), `[${shell}] cross-backend zz identical`);
		}
	} finally {
		fs.rmSync(nftDir, { recursive: true, force: true });
		fs.rmSync(iptDir, { recursive: true, force: true });
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
		for (const shell of ['dash', 'busybox']) {
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
else
	exit 0
fi
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		for (const shell of ['dash', 'busybox']) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const res = JSON.parse(raw);
			// merge: uci-only must be present (catches lost UCI when fragment overwrote)
			assert.equal(res.rules['uci-only'], 'uci-only', `[${shell}] uci+stream merge: uci-only present`);
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
		for (const shell of ['dash', 'busybox']) {
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
		for (const shell of ['dash', 'busybox']) {
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

function testIpv4Ipv6BothContributing() {
	// Both IPv4 and IPv6 fragments must contribute distinct keys, and duplicate
	// across fragments (fwlive-wan on both) must still be deduped via global OUT
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-stub-ip46-'));
	try {
		makeStub(stubDir, 'iptables-save', `#!/bin/sh
cat <<'EOF'
-A INPUT -j LOG --log-prefix "ipv4-rule "
-A INPUT -j LOG --log-prefix "fwlive-wan"
EOF
`);
		makeStub(stubDir, 'ip6tables-save', `#!/bin/sh
cat <<'EOF'
-A INPUT -j LOG --log-prefix "ipv6-rule "
-A INPUT -j LOG --log-prefix "fwlive-wan"
EOF
`);
		makeStub(stubDir, 'nft', `#!/bin/sh
exit 1
`);
		makeStub(stubDir, 'uci', `#!/bin/sh
exit 0
`);
		const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
		for (const shell of ['dash', 'busybox']) {
			let raw;
			try { raw = runWithShell(shell, env); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
			const res = JSON.parse(raw);
			assert.equal(res.backend, 'iptables', `[${shell}] backend iptables`);
			// both fragments contribute (catches only-first-fragment merge)
			assert.equal(res.rules['ipv4-rule'], 'ipv4 rule', `[${shell}] ipv4-rule present`);
			assert.equal(res.rules['ipv6-rule'], 'ipv6 rule', `[${shell}] ipv6-rule present`);
			// cross-fragment duplicate must be single (catches per-fragment OUT isolation)
			const cnt = (raw.match(/"fwlive-wan":/g) || []).length;
			assert.equal(cnt, 1, `[${shell}] cross-fragment fwlive-wan must be 1, got ${cnt} in ${raw}`);
			// raw must contain both distinct keys exactly once
			assert.equal((raw.match(/"ipv4-rule":/g) || []).length, 1, `[${shell}] ipv4 raw count 1`);
			assert.equal((raw.match(/"ipv6-rule":/g) || []).length, 1, `[${shell}] ipv6 raw count 1`);
		}
	} finally { fs.rmSync(stubDir, { recursive: true, force: true }); }
}

function testPollClampLinesContract() {
	// Verify poll_clamp_lines validates non-digit input (was trust-caller before)
	const shells = ['dash', 'busybox'];
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
	const shells = ['dash', 'busybox'];
	for (const shell of shells) {
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
			// clean any leftover nft/ipt/ip6t temps from prior runs (and prove no new file)
			try { execFileSync('sh', ['-c', 'rm -f /tmp/fwlive-nft.* /tmp/fwlive-ipt.* /tmp/fwlive-ip6t.* 2>/dev/null; true']); } catch {}
			const pre = (() => {
				try { return execFileSync('sh', ['-c', 'ls /tmp/fwlive-nft* /tmp/fwlive-ipt* /tmp/fwlive-ip6t* 2>/dev/null || true'], { encoding: 'utf8' }).trim(); } catch { return ''; }
			})();
			assert.equal(pre, '', `[${shell}] pre: no /tmp/fwlive-{nft,ipt,ip6t}* should exist before test`);
			const env = { ...process.env, PATH: `${stubDir}:${process.env.PATH}` };
			let raw;
			try {
				raw = runWithShell(shell, env);
			} catch (e) {
				if (e.code === 'ENOENT') continue;
				throw e;
			}
			// well-formed JSON and backend + UCI names must still be present
			let res;
			try { res = JSON.parse(raw); } catch (e) { throw new Error(`[${shell}] JSON malformed when mktemp absent: ${raw}: ${e.message}`); }
			assert.equal(res.backend, 'nft', `[${shell}] backend should still be nft when mktemp absent`);
			assert.equal(res.rules['uci-keep'], 'uci-keep', `[${shell}] uci-keep must survive mktemp absent (graceful degradation)`);
			assert.equal(res.rules['another-rule'], 'another-rule', `[${shell}] another-rule must survive`);
			// nft-derived enrichment must be skipped (no temp file to parse)
			assert.equal(res.rules['should-not-appear'], undefined, `[${shell}] nft enrichment must be skipped when mktemp absent, not written via fixed path`);
			// must not have created any nft/ipt/ip6t temp file
			const after = (() => {
				try { return execFileSync('sh', ['-c', 'ls /tmp/fwlive-nft* /tmp/fwlive-ipt* /tmp/fwlive-ip6t* 2>/dev/null || true'], { encoding: 'utf8' }).trim(); } catch { return ''; }
			})();
			assert.equal(after, '', `[${shell}] no /tmp/fwlive-{nft,ipt,ip6t}* file must be created when mktemp absent, got: ${after} (catches predictable-path write)`);
			// raw JSON must not contain the nft key at all
			assert.equal((raw.match(/"should-not-appear"/g) || []).length, 0, `[${shell}] raw must not contain should-not-appear`);
		} finally {
			fs.rmSync(stubDir, { recursive: true, force: true });
			try { execFileSync('sh', ['-c', 'rm -f /tmp/fwlive-nft.* /tmp/fwlive-ipt.* /tmp/fwlive-ip6t.* 2>/dev/null; true']); } catch {}
		}
	}
}

function run() {
	runRedirectPath();
	testProductionNft();
	testNftPrefixNormalization();
	testProductionIptables();
	testDuplicateKeys();
	testIdempotentNormalizationCrossBackend();
	testEmptyPrefixGuard();
	testUciStreamMergeAndCollision();
	testIpv4Ipv6BothContributing();
	testPollClampLinesContract();
	testNoMktempGracefulDegradation();
	console.log('fwlive rules map tests passed');
}

run();

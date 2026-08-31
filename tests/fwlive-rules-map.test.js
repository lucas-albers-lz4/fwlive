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

function runRedirectPath() {
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
			// log prefix labels must reach OUT (Task 1 regression) — exact key, not substring
			assert.equal(res.rules['fwlive-ssh'], 'Allow-SSH', `[${shell}] fwlive-ssh prefix should map to Allow-SSH`);
			// fwlive-ssh is already slugified, so only one key (duplicate skip)
			assert.equal(res.rules['My Prefix'], 'Allow-DNS', `[${shell}] My Prefix should map`);
			// slug for "My Prefix" is "my-prefix"
			assert.equal(res.rules['my-prefix'], 'Allow-DNS', `[${shell}] my-prefix slug`);
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
			// Exact key contract the client uses via parseRuleHint() — must be normalized
			assert.equal(res.rules['fwlive-ssh'], 'Allow-SSH', `[${shell}] trailing-space nft prefix must normalize to fwlive-ssh`);
			assert.equal(res.rules['fwlive-ssh '], undefined, `[${shell}] buggy trailing-space key must not exist`);
			assert.equal(res.rules['fwlive-ssh-'], undefined, `[${shell}] buggy slug from trailing space must not exist`);
			assert.equal(res.rules['fwlive-colon'], 'Allow-Colon', `[${shell}] trailing-colon nft prefix must normalize to fwlive-colon`);
			assert.equal(res.rules['fwlive-colon:'], undefined, `[${shell}] buggy colon key must not exist`);
			// Cosmetic values must not keep trailing space either
			assert.equal(res.rules['fwlive-lan'], 'fwlive lan', `[${shell}] cosmetic fwlive-lan must be trimmed`);
			assert.equal(res.rules['fwlive-lan '], undefined, `[${shell}] cosmetic trailing-space key must not exist`);
			assert.equal(res.rules['fwlive-lan-'], undefined, `[${shell}] cosmetic buggy slug must not exist`);
			assert.equal(res.rules['fwlive-trim'], 'fwlive trim', `[${shell}] cosmetic colon+space must normalize`);
			// fw4 comment-derived case must keep working (uci-style label with no spaces)
			assert.equal(res.rules['MyCustomRule'], 'MyCustomRule', `[${shell}] fw4 comment-derived label must map`);
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
		// Ensure no nft on PATH for this test: create a PATH without nft by using stubDir only plus a minimal PATH without nft
		// Use stubDir as first entry and ensure nft not found by not having it; system nft may exist, so we shadow with a failing stub
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
			// Task 1: iptables log-prefix must reach OUT
			// The stub emits fwlive-ssh and allow-dns; check they appear
			// Note: iptables parsing uses map_log_prefix_entry -> normalize_log_prefix
			assert.equal(res.rules['fwlive-ssh'], 'Allow-SSH', `[${shell}] iptables fwlive-ssh`);
			assert.equal(res.rules['allow-dns'], 'Allow-DNS', `[${shell}] iptables allow-dns slug or raw`);
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
			// both lookups must resolve
			assert.equal(res.rules['fwlive-wan'], 'fwlive wan', `[${shell}] raw lookup`);
			// slug is same as raw, so same value, but we check raw JSON string has no duplicate key
			const count = (raw.match(/"fwlive-wan"/g) || []).length;
			assert.equal(count, 1, `[${shell}] duplicate key fwlive-wan should appear exactly once, got ${count} in ${raw}`);
			// also test map_uci_style via iptables path with already-slugged key
			// ensure no duplicate for fwlive-wan in iptables stub
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
			const count = (raw.match(/"fwlive-wan"/g) || []).length;
			assert.equal(count, 1, `[${shell}] iptables duplicate key should be 1, got ${count} in ${raw}`);
		}
	} finally {
		fs.rmSync(stubDir2, { recursive: true, force: true });
	}
}

function run() {
	runRedirectPath();
	testProductionNft();
	testNftPrefixNormalization();
	testProductionIptables();
	testDuplicateKeys();
	console.log('fwlive rules map tests passed');
}

run();

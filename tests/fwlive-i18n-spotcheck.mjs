#!/usr/bin/env node
/**
 * Lab spot-check (#72 / #46 / #640): LuCI language de/ru/zh-cn shows fwlive toolbar strings.
 *
 * Prereqs (Playwright / QEMU): guest has luci-i18n-fwlive-<lang> (+ usually luci-i18n-base-<lang>).
 * scripts/qemu-i18n-spotcheck.sh force-reinstalls packages from out/ and sets luci.main.lang.
 *
 *   FWLIVE_URL=http://127.0.0.1:8080 FWLIVE_LANG=de node tests/fwlive-i18n-spotcheck.mjs
 *
 * Host (no QEMU): omit FWLIVE_LANG. Stubs ssh/node and asserts missing languages fail
 * with a DEGRADED verdict, and that already-installed packages are force-reinstalled.
 *
 *   node tests/fwlive-i18n-spotcheck.mjs
 */
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const BASE = process.env.FWLIVE_URL || 'http://127.0.0.1:8080';
const LANG = process.env.FWLIVE_LANG || '';
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = path.join(ROOT, 'scripts', 'qemu-i18n-spotcheck.sh');

/** Expected substrings for toolbar / title (from po files). */
const EXPECT = {
	de: [
		'Firewall-Live-Ansicht',
		'Protokollierung'
	],
	ru: [
		'Просмотр файрвола',
		'журнал'
	],
	'zh-cn': [
		'防火墙实时视图',
		'日志'
	]
};

async function login(page) {
	await page.goto(`${BASE}/cgi-bin/luci/admin/status/fwlive`, {
		waitUntil: 'networkidle',
		timeout: 60000
	});
	if (await page.locator('input[name="luci_username"]').count()) {
		await page.fill('input[name="luci_username"]', 'root');
		const pw = page.locator('input[name="luci_password"]');
		if (await pw.count())
			await pw.fill('');
		await page.click('button, input[type="submit"]');
		await page.waitForTimeout(1500);
		await page.goto(`${BASE}/cgi-bin/luci/admin/status/fwlive`, {
			waitUntil: 'networkidle',
			timeout: 60000
		});
	}
}

async function runPlaywright() {
	const needles = EXPECT[LANG];
	if (!needles)
		throw new Error(`unsupported FWLIVE_LANG=${LANG} (want de|ru|zh-cn)`);

	const { chromium } = await import('playwright');
	const browser = await chromium.launch({ headless: true });
	const page = await browser.newPage();
	page.on('pageerror', (e) => console.error('pageerror:', e.message));

	await login(page);
	await page.waitForTimeout(2000);

	const body = await page.locator('body').innerText();
	const missing = needles.filter((n) => !body.includes(n));
	if (missing.length) {
		const sample = body.replace(/\s+/g, ' ').slice(0, 500);
		throw new Error(
			`lang=${LANG}: missing translated strings ${JSON.stringify(missing)}; body sample: ${sample}`
		);
	}

	console.log(`fwlive i18n spotcheck OK (${LANG}): found ${needles.map(JSON.stringify).join(', ')}`);
	await browser.close();
}

function writeExec(file, body) {
	fs.writeFileSync(file, body, { mode: 0o755 });
}

function runSpotcheck(opts) {
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-i18n-spotcheck.'));
	const bin = path.join(tmp, 'bin');
	const i18nDir = path.join(tmp, 'i18n');
	const logFile = path.join(tmp, 'ssh.log');
	fs.mkdirSync(bin);
	fs.mkdirSync(i18nDir);
	fs.writeFileSync(logFile, '');

	for (const lang of opts.langs || []) {
		fs.writeFileSync(
			path.join(i18nDir, `luci-i18n-fwlive-${lang}_0.1.45-1_all.ipk`),
			'fake-ipk\n'
		);
	}
	if (opts.apkLangs) {
		for (const lang of opts.apkLangs) {
			fs.writeFileSync(
				path.join(i18nDir, `luci-i18n-fwlive-${lang}_0.1.45-1_all.apk`),
				'fake-apk\n'
			);
		}
	}

	writeExec(path.join(bin, 'ssh'), `#!/bin/sh
last=''
for arg do last="$arg"; done
printf 'ssh %s\\n' "$last" >>"\${FWLIVE_STUB_LOG:?}"
case "$last" in
	'echo connected') echo connected ;;
	'uci -q get luci.main.lang') exit 1 ;;
	*'uci -q delete luci.main.lang'*) exit 0 ;;
	*'uci set luci.main.lang='*) exit 0 ;;
	*'uci commit luci'*) exit 0 ;;
	'command -v apk >/dev/null 2>&1')
		if [ "\${FWLIVE_STUB_HAS_APK:-0}" = 1 ]; then exit 0; else exit 1; fi
		;;
	'command -v opkg >/dev/null 2>&1') exit 0 ;;
	'apk update >/dev/null 2>&1 || true') exit 0 ;;
	'opkg update >/dev/null 2>&1 || true') exit 0 ;;
	*'apk add luci-i18n-base-'*) exit 0 ;;
	*'opkg list-installed | grep -q'*)
		# Pretend base *and* fwlive packs are already installed (stale).
		exit 0
		;;
	*'opkg install luci-i18n-base-'*) exit 0 ;;
	*'apk add --allow-untrusted --force-reinstall '*) exit 0 ;;
	*'opkg install --force-reinstall '*) exit 0 ;;
	cat\\ \\>*) cat >/dev/null; exit 0 ;;
	*) echo "unexpected remote command: $last" >&2; exit 1 ;;
esac
`);

	writeExec(path.join(bin, 'node'), `#!/bin/sh
printf 'node %s\\n' "$*" >>"\${FWLIVE_STUB_LOG:?}"
echo "fwlive i18n spotcheck OK stub"
exit 0
`);

	const env = {
		...process.env,
		PATH: `${bin}:${process.env.PATH || '/usr/bin'}`,
		NODE: path.join(bin, 'node'),
		FWLIVE_I18N_DIR: i18nDir,
		FWLIVE_STUB_LOG: logFile,
		FWLIVE_STUB_HAS_APK: opts.apk ? '1' : '0',
		OPENWRT_HOST: '127.0.0.1',
		OPENWRT_SSH_PORT: '2222'
	};
	delete env.FWLIVE_LANG;
	delete env.FWLIVE_URL;

	const result = spawnSync('bash', [SCRIPT], {
		encoding: 'utf8',
		env
	});
	const log = fs.existsSync(logFile) ? fs.readFileSync(logFile, 'utf8') : '';
	const text = `${result.stdout || ''}\n${result.stderr || ''}`;
	fs.rmSync(tmp, { recursive: true, force: true });
	return { status: result.status, text, log };
}

function runHostTests() {
	const scriptSrc = fs.readFileSync(SCRIPT, 'utf8');
	assert.match(scriptSrc, /opkg install --force-reinstall/);
	assert.match(scriptSrc, /apk add --allow-untrusted --force-reinstall/);
	assert.equal(
		scriptSrc.includes('already installed'),
		false,
		'script must not short-circuit on already-installed fwlive i18n packages'
	);

	const missing = runSpotcheck({ langs: ['de'] });
	assert.notEqual(missing.status, 0, 'missing expected languages must fail');
	assert.match(
		missing.text,
		/DEGRADED: covered=\[de\] missing=\[ru zh-cn\]/,
		'missing-language run must print a loud covered vs missing verdict'
	);
	assert.match(missing.text, /FAIL: expected languages not covered: ru zh-cn/);
	assert.match(
		missing.log,
		/opkg install --force-reinstall /,
		'present language must still force-reinstall from the artifact'
	);
	assert.equal(
		missing.log.includes('already installed'),
		false,
		'stale already-installed packages must not skip reinstall'
	);

	const okRun = runSpotcheck({ langs: ['de', 'ru', 'zh-cn'] });
	assert.equal(okRun.status, 0, `full language set must pass: ${okRun.text}`);
	assert.match(okRun.text, /covered=\[de ru zh-cn\] missing=\[\]/);
	assert.match(okRun.log, /opkg install --force-reinstall '/);
	assert.equal((okRun.log.match(/opkg install --force-reinstall /g) || []).length, 3);

	const apkRun = runSpotcheck({ apk: true, apkLangs: ['de'] });
	assert.notEqual(apkRun.status, 0, 'apk missing-language run must fail');
	assert.match(apkRun.text, /DEGRADED: covered=\[de\] missing=\[ru zh-cn\]/);
	assert.match(apkRun.log, /apk add --allow-untrusted --force-reinstall /);

	console.log('fwlive i18n spotcheck host tests passed (missing-language DEGRADED + force-reinstall)');
}

if (LANG) {
	runPlaywright().catch((e) => {
		console.error(e);
		process.exit(1);
	});
} else {
	try {
		runHostTests();
	} catch (e) {
		console.error(e);
		process.exit(1);
	}
}

#!/usr/bin/env node
/**
 * Lab spot-check (#72 / #46): LuCI language de/ru/zh-cn shows fwlive toolbar strings.
 *
 * Prereqs: guest has luci-i18n-fwlive-<lang> (+ usually luci-i18n-base-<lang>).
 * scripts/qemu-i18n-spotcheck.sh installs packages and sets luci.main.lang.
 *
 *   FWLIVE_URL=http://127.0.0.1:8080 FWLIVE_LANG=de node tests/fwlive-i18n-spotcheck.mjs
 */
import { chromium } from 'playwright';

const BASE = process.env.FWLIVE_URL || 'http://127.0.0.1:8080';
const LANG = process.env.FWLIVE_LANG || 'de';

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

async function main() {
	const needles = EXPECT[LANG];
	if (!needles)
		throw new Error(`unsupported FWLIVE_LANG=${LANG} (want de|ru|zh-cn)`);

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

main().catch((e) => {
	console.error(e);
	process.exit(1);
});

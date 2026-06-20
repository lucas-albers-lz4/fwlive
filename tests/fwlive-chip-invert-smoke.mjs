#!/usr/bin/env node
import { chromium } from 'playwright';

const BASE = process.env.FWLIVE_URL || 'http://127.0.0.1:8080';

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
	}
}

async function assertInvert(page, { paused }) {
	await page.locator('.fwlive-chip-clear').click({ timeout: 2000 }).catch(() => {});
	await page.waitForTimeout(200);

	const refresh = page.locator('#fwlive-autorefresh');
	if (paused)
		await refresh.uncheck();
	else
		await refresh.check();

	await page.waitForSelector('#fwlive-table tbody tr', { timeout: 30000 });
	await page.locator('a.fwlive-filter-link', { hasText: /^pass$/i }).first().click();
	await page.waitForSelector('.fwlive-chip', { timeout: 5000 });
	await page.waitForTimeout(400);

	const passBefore = await page.locator('#fwlive-table tbody tr .fwlive-pass').count();
	await page.locator('.fwlive-chip-invert').first().click();
	await page.waitForTimeout(600);

	const chip = await page.locator('.fwlive-chip-label').first().textContent();
	const passAfter = await page.locator('#fwlive-table tbody tr .fwlive-pass').count();

	if (!chip.includes('not pass'))
		throw new Error(`expected negated chip while ${paused ? 'paused' : 'live'}, got: ${chip}`);

	if (passBefore > 0 && passAfter >= passBefore)
		throw new Error(`invert did not filter table while ${paused ? 'paused' : 'live'} (${passBefore} -> ${passAfter} pass rows)`);
}

async function main() {
	const browser = await chromium.launch({ headless: true });
	const page = await browser.newPage();
	page.on('pageerror', (e) => console.error('pageerror:', e.message));

	await login(page);
	await assertInvert(page, { paused: false });
	await assertInvert(page, { paused: true });

	console.log('fwlive chip invert smoke OK (live + paused)');
	await browser.close();
}

main().catch((e) => {
	console.error(e);
	process.exit(1);
});

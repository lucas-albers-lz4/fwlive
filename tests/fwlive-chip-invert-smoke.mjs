#!/usr/bin/env node
/**
 * Chip invert smoke against a running QEMU LuCI guest.
 *
 *   FWLIVE_URL=http://127.0.0.1:8080 node tests/fwlive-chip-invert-smoke.mjs
 *
 * Bundle: tests/fwlive-lab-playwright-bundle.mjs (shared context).
 */
import { isDirectRun, withLabPage } from './lib/playwright-lab.mjs';

async function assertInvert(page, { paused }) {
	await page.locator('.fwlive-chip-clear').click({ timeout: 2000 }).catch(() => {});
	await page.waitForTimeout(200);

	const refresh = page.locator('#fwlive-pause');
	const label = (await refresh.textContent() || '').trim();
	if (paused) {
		if (label === 'Pause')
			await refresh.click();
	} else {
		if (label === 'Resume')
			await refresh.click();
	}
	await page.waitForTimeout(200);
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

export async function runChipInvertSmoke(page) {
	await assertInvert(page, { paused: false });
	await assertInvert(page, { paused: true });
	console.log('fwlive chip invert smoke OK (live + paused)');
}

async function main() {
	await withLabPage(runChipInvertSmoke);
}

if (isDirectRun(import.meta.url)) {
	main().catch((e) => {
		console.error(e);
		process.exit(1);
	});
}

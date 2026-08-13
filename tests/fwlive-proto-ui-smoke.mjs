#!/usr/bin/env node
/**
 * Protocol pair + watch-strip segment smoke against a running QEMU LuCI guest.
 *
 *   FWLIVE_URL=http://127.0.0.1:8080 node tests/fwlive-proto-ui-smoke.mjs
 *
 * Covers: custom proto wins over menu, chip invert/clear for proto,
 * Detail/Message segmented aria-pressed.
 */
import { chromium } from 'playwright';

const BASE = process.env.FWLIVE_URL || 'http://127.0.0.1:8080';
const FWLIVE = `${BASE}/cgi-bin/luci/admin/status/fwlive`;

async function login(page) {
	await page.goto(FWLIVE, { waitUntil: 'domcontentloaded', timeout: 60000 });
	if (await page.locator('input[name="luci_username"]').count()) {
		await page.fill('input[name="luci_username"]', 'root');
		const pw = page.locator('input[name="luci_password"]');
		if (await pw.count())
			await pw.fill('');
		await Promise.all([
			page.waitForURL(/\/cgi-bin\/luci/, { timeout: 30000 }).catch(() => {}),
			page.click('button, input[type="submit"]')
		]);
		await page.goto(FWLIVE, { waitUntil: 'domcontentloaded', timeout: 60000 });
	}
	await page.waitForSelector('.fwlive-map', { timeout: 30000 });
}

async function clearFilters(page) {
	const clearAll = page.locator('a.fwlive-chip-clear');
	if (await clearAll.count())
		await clearAll.first().click().catch(() => {});
	await page.locator('#fwlive-proto').selectOption('');
	await page.locator('#fwlive-proto-custom').fill('');
	await page.waitForTimeout(250);
}

async function firstChipLabel(page) {
	const chip = page.locator('.fwlive-chip-label').first();
	if (!(await chip.count()))
		return '';
	return (await chip.textContent()) || '';
}

async function assertProtoCustomWins(page) {
	await clearFilters(page);
	await page.locator('#fwlive-proto').selectOption('TCP');
	await page.waitForSelector('.fwlive-chip', { timeout: 5000 });
	let chip = await firstChipLabel(page);
	if (!/TCP/i.test(chip))
		throw new Error(`expected TCP chip after menu select, got: ${chip}`);

	await page.locator('#fwlive-proto-custom').fill('esp');
	await page.waitForTimeout(600);
	const sel = await page.locator('#fwlive-proto').inputValue();
	chip = await firstChipLabel(page);
	if (sel !== '')
		throw new Error(`expected select cleared when typing custom, got select=${sel}`);
	if (!/esp/i.test(chip))
		throw new Error(`expected esp chip when custom wins, got: ${chip}`);

	await page.locator('button.fwlive-chip-invert').first().click();
	await page.waitForTimeout(400);
	chip = await firstChipLabel(page);
	const custom = await page.locator('#fwlive-proto-custom').inputValue();
	if (!(custom.startsWith('!') || /not/i.test(chip)))
		throw new Error(`expected inverted custom proto, chip=${chip} custom=${custom}`);

	await page.locator('a.fwlive-chip-remove').first().click();
	await page.waitForTimeout(300);
	if (await page.locator('.fwlive-chip').count())
		throw new Error('expected no chips after proto remove');
}

async function assertSegments(page) {
	const detail = page.locator('#fwlive-detail-toggle');
	const msg = page.locator('#fwlive-msg-layout');
	if (!(await detail.count()) || !(await msg.count()))
		throw new Error('missing Detail/Message segment buttons');

	const beforeDetail = await detail.getAttribute('aria-pressed');
	await detail.click();
	await page.waitForTimeout(300);
	const afterDetail = await detail.getAttribute('aria-pressed');
	const mapView = await page.locator('.fwlive-map').getAttribute('data-view');
	if (beforeDetail === afterDetail)
		throw new Error(`Detail aria-pressed did not toggle (${beforeDetail})`);
	if (afterDetail === 'true' && mapView !== 'detailed')
		throw new Error(`expected data-view=detailed, got ${mapView}`);
	if (afterDetail === 'false' && mapView !== 'simple')
		throw new Error(`expected data-view=simple, got ${mapView}`);

	/* Message control is hidden in Simple view — exercise it after Detail. */
	if (mapView !== 'detailed') {
		await detail.click();
		await page.waitForTimeout(300);
	}
	await expectVisible(page, '#fwlive-msg-layout');
	const beforeMsg = await msg.getAttribute('aria-pressed');
	await msg.click();
	await page.waitForTimeout(200);
	const afterMsg = await msg.getAttribute('aria-pressed');
	if (beforeMsg === afterMsg)
		throw new Error(`Message aria-pressed did not toggle (${beforeMsg})`);
}

async function expectVisible(page, selector) {
	await page.waitForSelector(selector, { state: 'visible', timeout: 5000 });
}

async function main() {
	const browser = await chromium.launch({ headless: true });
	const page = await browser.newPage();
	page.on('pageerror', (e) => console.error('pageerror:', e.message));

	await login(page);
	await page.waitForSelector('#fwlive-proto-custom', { timeout: 15000 });
	await assertProtoCustomWins(page);
	await assertSegments(page);

	console.log('fwlive proto UI smoke OK (custom wins + invert/clear + segments)');
	await browser.close();
}

main().catch((e) => {
	console.error(e);
	process.exit(1);
});

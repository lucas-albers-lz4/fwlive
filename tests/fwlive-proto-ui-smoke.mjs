#!/usr/bin/env node
/**
 * Protocol pair + watch-strip segment smoke against a running QEMU LuCI guest.
 *
 *   FWLIVE_URL=http://127.0.0.1:8080 node tests/fwlive-proto-ui-smoke.mjs
 *
 * Bundle: tests/fwlive-lab-playwright-bundle.mjs (shared context).
 *
 * Covers: custom proto wins over menu, chip invert/clear for proto,
 * Detail/Message segmented aria-pressed.
 */
import { isDirectRun, withLabPage } from './lib/playwright-lab.mjs';

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
	const simple = page.locator('#fwlive-view-simple');
	const detail = page.locator('#fwlive-view-detail');
	const wrap = page.locator('#fwlive-msg-wrap');
	const oneline = page.locator('#fwlive-msg-oneline');
	if (!(await simple.count()) || !(await detail.count())
		|| !(await wrap.count()) || !(await oneline.count()))
		throw new Error('missing View/Message segment buttons');

	const beforeDetail = await detail.getAttribute('aria-pressed');
	await detail.click();
	await page.waitForTimeout(300);
	const afterDetail = await detail.getAttribute('aria-pressed');
	const mapView = await page.locator('.fwlive-map').getAttribute('data-view');
	if (beforeDetail === afterDetail)
		throw new Error(`Detail aria-pressed did not toggle (${beforeDetail})`);
	if (afterDetail !== 'true' || mapView !== 'detailed')
		throw new Error(`expected data-view=detailed with Detail pressed, got view=${mapView} pressed=${afterDetail}`);

	await simple.click();
	await page.waitForTimeout(300);
	const simplePressed = await simple.getAttribute('aria-pressed');
	const simpleView = await page.locator('.fwlive-map').getAttribute('data-view');
	if (simplePressed !== 'true' || simpleView !== 'simple')
		throw new Error(`expected data-view=simple with Simple pressed, got view=${simpleView} pressed=${simplePressed}`);

	/* Message control is hidden in Simple view — exercise it after Detail. */
	await detail.click();
	await page.waitForTimeout(300);
	await expectVisible(page, '#fwlive-msg-seg');
	const beforeMsg = await oneline.getAttribute('aria-pressed');
	await oneline.click();
	await page.waitForTimeout(200);
	const afterMsg = await oneline.getAttribute('aria-pressed');
	if (beforeMsg === afterMsg)
		throw new Error(`One line aria-pressed did not toggle (${beforeMsg})`);
	if (afterMsg !== 'true')
		throw new Error(`expected One line pressed after click, got ${afterMsg}`);
}

async function expectVisible(page, selector) {
	await page.waitForSelector(selector, { state: 'visible', timeout: 5000 });
}

export async function runProtoUiSmoke(page) {
	await page.waitForSelector('#fwlive-proto-custom', { timeout: 15000 });
	await assertProtoCustomWins(page);
	await assertSegments(page);
	console.log('fwlive proto UI smoke OK (custom wins + invert/clear + segments)');
}

async function main() {
	await withLabPage(runProtoUiSmoke);
}

if (isDirectRun(import.meta.url)) {
	main().catch((e) => {
		console.error(e);
		process.exit(1);
	});
}

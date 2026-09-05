/**
 * Shared Chromium launch + LuCI login for lab Playwright smokes (Wave C2 / #240).
 *
 * One helper, one login path. Individual smokes and the lab bundle both use this
 * so Chromium startup is not re-copied per file.
 */
import { chromium } from 'playwright';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function labBaseUrl() {
	return process.env.FWLIVE_URL || 'http://127.0.0.1:8080';
}

export function labFwliveUrl() {
	return `${labBaseUrl()}/cgi-bin/luci/admin/status/fwlive`;
}

/** True when this module was the node argv entry (not imported by the bundle). */
export function isDirectRun(metaUrl) {
	if (!process.argv[1])
		return false;
	return fileURLToPath(metaUrl) === path.resolve(process.argv[1]);
}

export async function gotoFwlive(page) {
	await page.goto(labFwliveUrl(), { waitUntil: 'domcontentloaded', timeout: 60000 });
}

export async function waitForFwliveMap(page) {
	await page.waitForSelector('.fwlive-map', { timeout: 30000 });
}

export async function loginFwlive(page) {
	await gotoFwlive(page);
	if (await page.locator('input[name="luci_username"]').count()) {
		await page.fill('input[name="luci_username"]', 'root');
		const pw = page.locator('input[name="luci_password"]');
		if (await pw.count())
			await pw.fill('');
		await Promise.all([
			page.waitForURL(/\/cgi-bin\/luci/, { timeout: 30000 }).catch(() => {}),
			page.click('button, input[type="submit"]')
		]);
		await gotoFwlive(page);
	}
	await waitForFwliveMap(page);
}

export async function launchLabBrowser() {
	const browser = await chromium.launch({ headless: true });
	const context = await browser.newContext();
	const page = await context.newPage();
	page.on('pageerror', (e) => console.error('pageerror:', e.message));
	return { browser, context, page };
}

/** Launch, log in once, run fn(page), always close the browser. */
export async function withLabPage(fn) {
	const { browser, page } = await launchLabBrowser();
	try {
		await loginFwlive(page);
		await fn(page);
	} finally {
		await browser.close();
	}
}

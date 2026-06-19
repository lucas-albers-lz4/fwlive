#!/usr/bin/env node
/**
 * Capture Firewall Live View screenshots from QEMU lab LuCI.
 * Prereqs: guest running, fwlive installed, ping logs generated.
 *
 *   node scripts/capture-fwlive-screenshots.mjs
 */
import { chromium } from 'playwright';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'docs/user/assets');
const BASE = process.env.FWLIVE_LUCI_URL || 'http://127.0.0.1:8080';

async function login(page) {
	await page.goto(`${BASE}/cgi-bin/luci/`, { waitUntil: 'domcontentloaded' });
	const user = page.locator('#luci_username');
	if (!(await user.count()))
		return;

	await user.fill('root');
	await page.locator('button:has-text("Log in")').click();
	await page.waitForLoadState('networkidle');
}

async function openFwlive(page, hash = '') {
	await page.goto(`${BASE}/cgi-bin/luci/admin/status/fwlive${hash}`, {
		waitUntil: 'networkidle'
	});
	try {
		await page.waitForSelector('#fwlive-table', { timeout: 30000 });
	} catch (err) {
		await page.screenshot({ path: path.join(OUT, 'fwlive-debug.png'), fullPage: true });
		const title = await page.title();
		const body = await page.locator('body').innerText().catch(() => '');
		console.error('fwlive page failed to load. title:', title);
		console.error(body.slice(0, 800));
		throw err;
	}
	await page.waitForTimeout(2000);
}

async function enableDarkMode(page) {
	await page.evaluate(() => {
		document.documentElement.setAttribute('data-darkmode', 'true');
	});
}

async function main() {
	await mkdir(OUT, { recursive: true });

	const browser = await chromium.launch({ headless: true });
	const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

	await login(page);

	// Simple view (default) with icmp filter for chips
	await openFwlive(page, '#proto=icmp');
	await page.screenshot({ path: path.join(OUT, 'fwlive-simple-view.png'), fullPage: true });

	// Filter panel with chips (Simple)
	await page.locator('#fwlive-more-filters').evaluate((el) => { el.open = true; });
	await page.screenshot({ path: path.join(OUT, 'fwlive-filters.png'), fullPage: false,
		clip: { x: 0, y: 120, width: 1440, height: 280 } });

	// Expanded message row (Simple) — click Action cell to avoid filter links in Flow
	await openFwlive(page, '#proto=icmp');
	const actionCell = page.locator('#fwlive-table tbody tr.fwlive-row-clickable td').first();
	if (await actionCell.count()) {
		await actionCell.click();
		await page.waitForSelector('.fwlive-msg-expand', { timeout: 10000 });
		await page.locator('.fwlive-msg-expand').scrollIntoViewIfNeeded();
		await page.waitForTimeout(400);
		await page.screenshot({ path: path.join(OUT, 'fwlive-expanded-message.png'), fullPage: false,
			clip: { x: 0, y: 280, width: 1440, height: 420 } });
	}

	// Detailed view
	await page.locator('#fwlive-detail-toggle').click();
	await page.waitForTimeout(1500);
	await page.screenshot({ path: path.join(OUT, 'fwlive-main-view.png'), fullPage: true });

	// Dark mode (LuCI bootstrap data-darkmode)
	await enableDarkMode(page);
	await openFwlive(page, '#proto=icmp');
	await page.screenshot({ path: path.join(OUT, 'fwlive-dark-mode.png'), fullPage: true });

	await browser.close();
	console.log('Screenshots written to', OUT);
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});

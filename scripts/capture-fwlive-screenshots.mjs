#!/usr/bin/env node
/**
 * Capture Firewall Live View screenshots from QEMU lab LuCI.
 * Prereqs: guest running, fwlive installed. Ping helper is invoked mid-run
 * after the empty / after-Enable shots.
 *
 *   node scripts/capture-fwlive-screenshots.mjs
 */
import { chromium } from 'playwright';
import { mkdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'docs/user/assets');
const BASE = process.env.FWLIVE_LUCI_URL || 'http://127.0.0.1:8080';
const CONSENT_KEY = 'fwlive-logging-consent-v1';

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

async function clearConsent(page) {
	await page.evaluate((key) => {
		try { localStorage.removeItem(key); } catch (e) { /* ignore */ }
	}, CONSENT_KEY);
}

async function ensureWanLoggingOff(page) {
	const onBtn = page.locator('#fwlive-logging-bar button', { hasText: 'WAN logging on' });
	if (await onBtn.count()) {
		await onBtn.click();
		await page.waitForTimeout(2500);
		await openFwlive(page);
	}
}

function guestSsh(cmd) {
	return spawnSync('ssh', [
		'-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
		'-p', process.env.OPENWRT_SSH_PORT || '2222', 'root@127.0.0.1', cmd
	], { encoding: 'utf8' });
}

/* Shot 1 needs a genuinely empty table: drop the ping rule and the log buffer. */
function resetGuestLogs() {
	spawnSync(path.join(ROOT, 'scripts/fwlive-nft-ping-log.sh'), ['remove', '--ssh'], {
		cwd: ROOT, encoding: 'utf8'
	});
	const r = guestSsh('/etc/init.d/log restart; sleep 2; logread -c 2>/dev/null || true');
	if (r.status !== 0)
		console.warn('guest log reset:', r.stderr || r.stdout);
}

function runPingHelper() {
	const script = path.join(ROOT, 'scripts/fwlive-nft-ping-log.sh');
	let r = spawnSync(script, ['add', '--ssh'], { cwd: ROOT, encoding: 'utf8' });
	if (r.status !== 0)
		console.warn('fwlive-nft-ping-log add:', r.stderr || r.stdout);
	r = spawnSync('ssh', [
		'-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
		'-p', process.env.OPENWRT_SSH_PORT || '2222', 'root@127.0.0.1',
		'ping -c 15 127.0.0.1'
	], { encoding: 'utf8' });
	if (r.status !== 0)
		console.warn('guest ping:', r.stderr || r.stdout);
}

/* Row clicks can toggle a filter chip instead of expanding, so try a few rows. */
async function expandFirstRow(page) {
	const rows = page.locator('#fwlive-table tbody tr.fwlive-row-clickable');
	const count = Math.min(await rows.count(), 5);
	for (let i = 0; i < count; i++) {
		await rows.nth(i).locator('td').first().click();
		await page.waitForTimeout(400);
		if (await page.locator('.fwlive-msg-expand').count())
			return true;
	}
	return false;
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
	await openFwlive(page);
	await clearConsent(page);
	await ensureWanLoggingOff(page);
	resetGuestLogs();
	await clearConsent(page);
	await openFwlive(page);

	// Shot 1 — first visit: consent + logging off
	await page.waitForSelector('#fwlive-empty', { state: 'visible', timeout: 15000 });
	await page.waitForSelector('#fwlive-consent', { timeout: 10000 }).catch(() => {});
	await page.screenshot({ path: path.join(OUT, 'fwlive-empty-logging-off.png'), fullPage: true });

	// Shot 2 — Enable logging
	const enableBtn = page.locator('#fwlive-empty button.cbi-button-action').first();
	await enableBtn.click();
	await page.waitForTimeout(3000);
	await page.waitForSelector('text=WAN logging on', { timeout: 20000 });
	await page.screenshot({ path: path.join(OUT, 'fwlive-after-enable.png'), fullPage: true });

	// Generate visible rows
	runPingHelper();
	await openFwlive(page, '#proto=icmp');
	await page.waitForTimeout(3000);

	await page.screenshot({ path: path.join(OUT, 'fwlive-simple-view.png'), fullPage: true });

	await page.locator('#fwlive-more-filters').evaluate((el) => { el.open = true; });
	await page.waitForTimeout(300);
	if (!(await page.locator('#fwlive-chips .fwlive-chip').count())) {
		const cell = page.locator('#fwlive-table tbody tr td.fwlive-action').first();
		if (await cell.count())
			await cell.click();
		await page.waitForTimeout(400);
	}
	const filterBox = await page.locator('#fwlive-filter-panel').boundingBox().catch(() => null);
	const chipsBox = await page.locator('#fwlive-chips').boundingBox().catch(() => null);
	const hintBox = await page.locator('.fwlive-hint-line').boundingBox().catch(() => null);
	if (filterBox) {
		const y = Math.max(0, filterBox.y - 8);
		const bottom = Math.max(
			filterBox.y + filterBox.height,
			chipsBox ? chipsBox.y + chipsBox.height : 0,
			hintBox ? hintBox.y + hintBox.height : 0
		);
		await page.screenshot({
			path: path.join(OUT, 'fwlive-filters.png'),
			fullPage: false,
			clip: { x: 0, y, width: 1440, height: Math.min(500, bottom - y + 16) }
		});
	} else {
		await page.screenshot({
			path: path.join(OUT, 'fwlive-filters.png'),
			fullPage: false,
			clip: { x: 0, y: 100, width: 1440, height: 320 }
		});
	}

	runPingHelper();
	await openFwlive(page, '#proto=icmp');
	if (await expandFirstRow(page)) {
		await page.locator('.fwlive-msg-expand').scrollIntoViewIfNeeded();
		await page.waitForTimeout(400);
		const expandBox = await page.locator('#fwlive-scroll').boundingBox();
		if (expandBox) {
			await page.screenshot({
				path: path.join(OUT, 'fwlive-expanded-message.png'),
				fullPage: false,
				clip: {
					x: 0,
					y: Math.max(0, expandBox.y - 40),
					width: 1440,
					height: Math.min(480, expandBox.height + 60)
				}
			});
		} else {
			await page.screenshot({ path: path.join(OUT, 'fwlive-expanded-message.png'), fullPage: true });
		}
	} else {
		console.warn('no expandable row found; kept previous fwlive-expanded-message.png');
	}

	await page.locator('#fwlive-view-detail').click();
	await page.waitForTimeout(1500);
	await page.screenshot({ path: path.join(OUT, 'fwlive-main-view.png'), fullPage: true });

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

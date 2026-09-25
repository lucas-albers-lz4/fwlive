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
	/* Guest may leave /tmp/.uci staged (@zone vs cfgXXXX) so the UI toggle
	 * returns firewall_changes_pending. Force off via UCI for shot 1. */
	if (await page.locator('#fwlive-logging-bar button', { hasText: 'WAN logging on' }).count()) {
		requireOk(guestSetWanLog('0'), 'force WAN logging off');
		await openFwlive(page);
	}
}

function guestSsh(cmd) {
	return spawnSync('ssh', [
		'-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
		'-p', process.env.OPENWRT_SSH_PORT || '2222',
		`root@${process.env.OPENWRT_HOST || '127.0.0.1'}`,
		cmd
	], { encoding: 'utf8' });
}

function requireOk(r, label) {
	if (r.status === 0)
		return r;
	const detail = (r.stderr || r.stdout || r.error?.message || `exit ${r.status}`).trim();
	throw new Error(`${label}: ${detail}`);
}

/* Keep the first failing status, then always recreate /tmp/.uci. */
function guestUciFirewall(inner) {
	return guestSsh(
		'st=0; keep() { e=$?; [ "$st" -eq 0 ] && st=$e; return 0; }; ' +
		'rm -rf /tmp/.uci; mkdir -m 0700 /tmp/.uci || exit 1; ' +
		inner +
		'; rm -rf /tmp/.uci; mkdir -m 0700 /tmp/.uci || keep; exit "$st"'
	);
}

function guestSetWanLog(value) {
	if (value !== '0' && value !== '1')
		throw new Error(`guestSetWanLog: unexpected value ${JSON.stringify(value)}`);
	return guestUciFirewall(
		'zid=$(ubus call fwlive logging_status 2>/dev/null | jsonfilter -e \'$.wan_zone\' 2>/dev/null); ' +
		'if [ -z "$zid" ]; then echo \'fwlive: WAN zone lookup failed\' >&2; st=1; ' +
		'else uci set "firewall.$zid.log=' + value + '" || keep; ' +
		'uci commit firewall || keep; /etc/init.d/firewall reload || keep; fi'
	);
}

function snapshotGuestWanLogging() {
	const r = guestSsh("zid=$(ubus call fwlive logging_status 2>/dev/null | jsonfilter -e '$.wan_zone' 2>/dev/null); [ -n \"$zid\" ] || { echo 'fwlive: WAN zone lookup failed' >&2; exit 1; }; printf '%s\\n' \"$zid\"; uci -q get \"firewall.$zid.log\" || true");
	requireOk(r, 'snapshot guest WAN logging');
	const lines = (r.stdout || '').replace(/\r/g, '').split('\n');
	const zid = (lines[0] || '').trim();
	if (!zid)
		throw new Error('snapshot guest WAN logging: empty wan_zone');
	const logValue = (lines[1] || '').trim();
	return { zid, logValue: logValue === '' ? null : logValue };
}

function restoreGuestWanLogging(snap) {
	if (!snap || !snap.zid)
		return;
	if (snap.logValue != null && !/^[0-9]+$/.test(snap.logValue))
		throw new Error(`restore guest WAN logging: unexpected log value ${JSON.stringify(snap.logValue)}`);
	const uciOp = snap.logValue == null
		? 'uci -q delete "firewall.$zid.log" || true'
		: 'uci set "firewall.$zid.log=' + snap.logValue + '" || keep';
	const r = guestUciFirewall(
		'zid=$(ubus call fwlive logging_status 2>/dev/null | jsonfilter -e \'$.wan_zone\' 2>/dev/null); ' +
		'[ -n "$zid" ] || zid=' + JSON.stringify(snap.zid) + '; ' +
		'if [ -z "$zid" ]; then echo \'fwlive: WAN zone lookup failed\' >&2; st=1; ' +
		'else ' + uciOp + '; uci commit firewall || keep; /etc/init.d/firewall reload || keep; fi'
	);
	requireOk(r, 'restore guest WAN logging');
}

/* Shot 1 needs a genuinely empty table: drop the ping rule and the log buffer. */
function resetGuestLogs() {
	const rm = spawnSync(path.join(ROOT, 'scripts/fwlive-nft-ping-log.sh'), ['remove', '--ssh'], {
		cwd: ROOT, encoding: 'utf8'
	});
	requireOk(rm, 'fwlive-nft-ping-log remove');
	requireOk(guestSsh('st=0; /etc/init.d/log restart || st=$?; sleep 2; logread -c 2>/dev/null || true; exit "$st"'), 'guest log reset');
}

function runPingHelper() {
	const script = path.join(ROOT, 'scripts/fwlive-nft-ping-log.sh');
	requireOk(spawnSync(script, ['add', '--ssh'], { cwd: ROOT, encoding: 'utf8' }), 'fwlive-nft-ping-log add');
	requireOk(guestSsh('ping -c 15 127.0.0.1'), 'guest ping');
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

async function assertTableHasRows(page) {
	const count = await page.locator('#fwlive-table tbody tr').count()
		|| await page.locator('.fwlive-row-clickable').count();
	if (count === 0)
		throw new Error('fwlive table has no rendered rows; refusing row-bearing screenshots');
}

async function enableDarkMode(page) {
	await page.evaluate(() => {
		document.documentElement.setAttribute('data-darkmode', 'true');
	});
}

async function main() {
	await mkdir(OUT, { recursive: true });

	const wanLog = snapshotGuestWanLogging();
	let browser;
	try {
		browser = await chromium.launch({ headless: true });
		const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
		await login(page);
		await openFwlive(page);
		await clearConsent(page);
		await ensureWanLoggingOff(page);
		let logResetErr = null;
		try {
			resetGuestLogs();
		} catch (err) {
			logResetErr = err;
		}
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
		const loggingOnBtn = page.locator('#fwlive-logging-bar button', { hasText: 'WAN logging on' });
		if (!(await loggingOnBtn.count())) {
			/* Same UCI fallback when enable_wan_logging hits firewall_changes_pending. */
			requireOk(guestSetWanLog('1'), 'force WAN logging on');
			await openFwlive(page);
		}
		await loggingOnBtn.waitFor({ state: 'visible', timeout: 20000 });
		await page.screenshot({ path: path.join(OUT, 'fwlive-after-enable.png'), fullPage: true });

		// Generate visible rows — seed failures are fatal for this group
		if (logResetErr)
			throw logResetErr;
		runPingHelper();
		await openFwlive(page, '#proto=icmp');
		await page.waitForTimeout(3000);

		await assertTableHasRows(page);
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
		await assertTableHasRows(page);
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
		await assertTableHasRows(page);
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
		await assertTableHasRows(page);
		await page.screenshot({ path: path.join(OUT, 'fwlive-main-view.png'), fullPage: true });

		await enableDarkMode(page);
		await openFwlive(page, '#proto=icmp');
		await assertTableHasRows(page);
		await page.screenshot({ path: path.join(OUT, 'fwlive-dark-mode.png'), fullPage: true });

		console.log('Screenshots written to', OUT);
	} finally {
		try {
			restoreGuestWanLogging(wanLog);
		} catch (err) {
			console.error(err);
			process.exitCode = 1;
		}
		if (browser)
			await browser.close();
	}
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});

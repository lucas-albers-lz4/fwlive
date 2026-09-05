#!/usr/bin/env node
/**
 * Mocked LuCI view Playwright smoke (Tier 2 / #240 Wave B2) — no QEMU.
 * Hardens pageerror / cleanup / hostname resolve assertions (#249).
 *
 *   npm run test:view
 */
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.FWLIVE_HARNESS_PORT || 8765);
const EXTERNAL_URL = process.env.FWLIVE_HARNESS_URL || '';
const BASE = EXTERNAL_URL || `http://127.0.0.1:${PORT}`;

async function waitForHarness(page) {
	await page.goto(`${BASE}/tests/fixtures/luci-view-harness.html`, {
		waitUntil: 'domcontentloaded',
		timeout: 30000
	});
	await page.waitForFunction(() => window.fwliveView != null, { timeout: 30000 });
	await page.waitForSelector('#fwlive-table tbody tr', { timeout: 30000 });
}

async function testInitialRender(page) {
	const rows = await page.locator('#fwlive-table tbody tr').count();
	if (rows < 1)
		throw new Error('expected at least one table row after initial render');
	console.log('OK: initial render');
}

async function testPauseResume(page) {
	const pauseBtn = page.locator('#fwlive-pause');
	await pauseBtn.click();
	await page.waitForFunction(() => {
		const map = document.querySelector('.fwlive-map');
		return map && map.classList.contains('fwlive-watch-paused');
	}, { timeout: 10000 });
	await pauseBtn.click();
	await page.waitForFunction(() => {
		const map = document.querySelector('.fwlive-map');
		return map && !map.classList.contains('fwlive-watch-paused');
	}, { timeout: 10000 });
	console.log('OK: pause/resume toggle');
}

async function testDisplayDrawer(page) {
	await page.waitForSelector('#fwlive-display-drawer', { timeout: 10000 });
	await page.waitForSelector('#fwlive-limit', { timeout: 10000 });
	const visible = await page.locator('#fwlive-display-drawer').isVisible();
	if (!visible)
		throw new Error('display drawer must be visible');
	console.log('OK: display drawer');
}

async function clearFilters(page) {
	await page.locator('#fwlive-proto').selectOption('');
	await page.locator('#fwlive-proto-custom').fill('');
	await page.locator('#fwlive-action').selectOption('');
	await page.locator('#fwlive-q').fill('');
	const clearAll = page.locator('a.fwlive-chip-clear');
	if (await clearAll.count())
		await clearAll.first().click();
	await page.waitForFunction(() => document.querySelectorAll('.fwlive-chip').length === 0, {
		timeout: 5000
	});
}

async function testProtoCustomWins(page) {
	await clearFilters(page);
	await page.locator('#fwlive-proto').selectOption('TCP');
	await page.waitForSelector('.fwlive-chip', { timeout: 5000 });
	let chip = await page.locator('.fwlive-chip-label').first().textContent();
	if (!/TCP/i.test(chip || ''))
		throw new Error(`expected TCP chip, got: ${chip}`);

	await page.locator('#fwlive-proto-custom').fill('esp');
	await page.waitForFunction(() => {
		const sel = document.getElementById('fwlive-proto');
		const chip = document.querySelector('.fwlive-chip-label');
		return sel && sel.value === '' && chip && /esp/i.test(chip.textContent || '');
	}, { timeout: 5000 });
	const sel = await page.locator('#fwlive-proto').inputValue();
	chip = await page.locator('.fwlive-chip-label').first().textContent();
	if (sel !== '')
		throw new Error(`expected select cleared when typing custom, got select=${sel}`);
	if (!/esp/i.test(chip || ''))
		throw new Error(`expected esp chip from custom input, got: ${chip}`);
	console.log('OK: proto custom wins');
}

async function testChipInvert(page) {
	await clearFilters(page);
	await page.locator('a.fwlive-filter-link', { hasText: /^pass$/i }).first().click();
	await page.waitForSelector('.fwlive-chip', { timeout: 5000 });
	const before = await page.locator('.fwlive-chip-label').first().textContent();
	await page.locator('.fwlive-chip-invert').first().click();
	await page.waitForFunction(() => {
		const chip = document.querySelector('.fwlive-chip-label');
		return chip && /not pass/i.test(chip.textContent || '');
	}, { timeout: 5000 });
	const after = await page.locator('.fwlive-chip-label').first().textContent();
	if (before === after || !/not pass/i.test(after || ''))
		throw new Error(`chip invert failed: ${before} -> ${after}`);
	console.log('OK: chip invert');
}

async function testSegmentToggles(page) {
	const detail = page.locator('#fwlive-view-detail');
	await detail.click();
	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-view-detail');
		return el && el.getAttribute('aria-pressed') === 'true';
	}, { timeout: 5000 });

	const oneline = page.locator('#fwlive-msg-oneline');
	if (await oneline.count()) {
		await oneline.click();
		await page.waitForFunction(() => {
			const el = document.getElementById('fwlive-msg-oneline');
			return el && el.getAttribute('aria-pressed') === 'true';
		}, { timeout: 5000 });
	}
	console.log('OK: segment aria-pressed toggles');
}

async function testHostnamesToggle(page) {
	await clearFilters(page);
	/* Simple view so filteredRows() still has the canned log IPs. */
	const simple = page.locator('#fwlive-view-simple');
	if (await simple.count())
		await simple.click();

	await page.evaluate(() => {
		window.fwliveResolveCalls = [];
		const v = window.fwliveView;
		if (v.hostnameCache)
			v.hostnameCache.clear();
		if (v.hostnameFailed)
			v.hostnameFailed.clear();
		v.resolveInFlight = false;
	});

	const cb = page.locator('#fwlive-show-hostnames');
	if (await cb.isChecked())
		await cb.uncheck();
	const genBefore = await page.evaluate(() => window.fwliveView.resolveGeneration);
	await cb.check();

	await page.waitForFunction(() => {
		const v = window.fwliveView;
		return v &&
			window.fwliveResolveCalls.length > 0 &&
			v.hostnameCache &&
			v.hostnameCache.has('192.0.2.1') &&
			v.hostnameCache.get('192.0.2.1') === 'src-host';
	}, { timeout: 10000 });

	const genAfter = await page.evaluate(() => window.fwliveView.resolveGeneration);
	if (genAfter <= genBefore)
		throw new Error('hostnames toggle must bump resolveGeneration');

	const calls = await page.evaluate(() => window.fwliveResolveCalls);
	if (!calls.length || !calls[0].includes('192.0.2.1'))
		throw new Error('resolve RPC must be called with row IPs, got: ' + JSON.stringify(calls));

	console.log('OK: hostnames resolve called and names applied');
}

async function testPollErrorBanner(page) {
	await page.evaluate(async () => {
		window.__fwlivePrevPollMock = window.setFwlivePollMock(function() {
			return { log: [], error: 'filter_failed' };
		});
		await window.fwliveView.fetchEntries();
		window.fwliveView.updateStatus();
	});
	try {
		await page.waitForFunction(() => {
			const el = document.getElementById('fwlive-status');
			return el && /Connection lost/i.test(el.textContent || '');
		}, { timeout: 10000 });
		console.log('OK: poll error banner (#233)');
	} finally {
		await page.evaluate(() => {
			if (typeof window.__fwlivePrevPollMock !== 'undefined') {
				window.setFwlivePollMock(window.__fwlivePrevPollMock);
				delete window.__fwlivePrevPollMock;
			}
		});
	}
}

async function testRulesTruncatedDegraded(page) {
	/* Tier-2 Gap 1 (#274): a truncated rules reply degrades the backend span
	 * while the counter and paused class still render (~256-rules shape). */
	const pauseBtn = page.locator('#fwlive-pause');
	await pauseBtn.click();
	await page.waitForFunction(() => {
		const map = document.querySelector('.fwlive-map');
		return map && map.classList.contains('fwlive-watch-paused');
	}, { timeout: 10000 });
	try {
		await page.evaluate(async () => {
			window.__fwlivePrevRulesMock = window.setFwliveRulesMock(function() {
				return { rules: {}, error: 'rules_truncated' };
			});
			await window.fwliveView.loadRulesMap();
			window.fwliveView.updateStatus();
		});
		await page.waitForFunction(() => {
			const el = document.getElementById('fwlive-backend');
			return el && /map truncated/i.test(el.textContent || '');
		}, { timeout: 10000 });
		const status = await page.locator('#fwlive-status').textContent();
		if (!/matching/i.test(status || ''))
			throw new Error('counter must still render under rules_truncated, got: ' + status);
		const paused = await page.evaluate(() => {
			const map = document.querySelector('.fwlive-map');
			return !!(map && map.classList.contains('fwlive-watch-paused'));
		});
		if (!paused)
			throw new Error('paused class must survive rules_truncated');
		console.log('OK: rules_truncated backend-span + counter/paused (#274)');
	} finally {
		await page.evaluate(async () => {
			if (typeof window.__fwlivePrevRulesMock !== 'undefined') {
				window.setFwliveRulesMock(window.__fwlivePrevRulesMock);
				delete window.__fwlivePrevRulesMock;
			}
			await window.fwliveView.loadRulesMap();
			window.fwliveView.updateStatus();
		});
		await pauseBtn.click();
		await page.waitForFunction(() => {
			const map = document.querySelector('.fwlive-map');
			return map && !map.classList.contains('fwlive-watch-paused');
		}, { timeout: 10000 });
	}
}

async function runSmoke(browser) {
	const pageErrors = [];
	const page = await browser.newPage();
	page.on('pageerror', (e) => {
		pageErrors.push(e.message);
		console.error('pageerror:', e.message);
	});

	try {
		await waitForHarness(page);
		await testInitialRender(page);
		await testPauseResume(page);
		await testDisplayDrawer(page);
		await testProtoCustomWins(page);
		await testChipInvert(page);
		await testSegmentToggles(page);
		await testHostnamesToggle(page);
		await testPollErrorBanner(page);
		await testRulesTruncatedDegraded(page);

		if (pageErrors.length)
			throw new Error('pageerror(s) during smoke: ' + pageErrors.join('; '));

		console.log('fwlive view smoke OK (mocked harness)');
	} finally {
		await page.close().catch(() => {});
	}
}

function spawnHarnessServer() {
	return spawn(process.execPath, ['scripts/serve-view-harness.mjs'], {
		cwd: ROOT,
		env: {
			...process.env,
			FWLIVE_HARNESS_PORT: String(PORT),
			FWLIVE_HARNESS_HOST: '127.0.0.1'
		},
		stdio: ['ignore', 'pipe', 'pipe']
	});
}

function waitForServerReady(child) {
	return new Promise((resolve, reject) => {
		let settled = false;
		const timer = setTimeout(() => {
			if (!settled) {
				settled = true;
				reject(new Error('harness server start timeout'));
			}
		}, 15000);
		child.stdout.on('data', (chunk) => {
			if (/fwlive view harness/.test(String(chunk)) && !settled) {
				settled = true;
				clearTimeout(timer);
				resolve();
			}
		});
		child.stderr.on('data', (chunk) => {
			process.stderr.write(chunk);
		});
		child.on('error', (err) => {
			if (!settled) {
				settled = true;
				clearTimeout(timer);
				reject(err);
			}
		});
		child.on('exit', (code) => {
			if (!settled) {
				settled = true;
				clearTimeout(timer);
				reject(new Error('harness server exited early: ' + code));
			}
		});
	});
}

function stopChild(child) {
	if (!child || child.killed || child.exitCode != null)
		return Promise.resolve();
	return new Promise((resolve) => {
		const t = setTimeout(() => {
			try { child.kill('SIGKILL'); } catch (e) { /* ignore */ }
			resolve();
		}, 3000);
		child.once('exit', () => {
			clearTimeout(t);
			resolve();
		});
		try { child.kill('SIGTERM'); } catch (e) { clearTimeout(t); resolve(); }
	});
}

async function mainWithServer() {
	const child = spawnHarnessServer();
	let browser;
	try {
		await waitForServerReady(child);
		browser = await chromium.launch({ headless: true });
		await runSmoke(browser);
	} finally {
		if (browser)
			await browser.close().catch(() => {});
		await stopChild(child);
	}
}

async function mainDirect() {
	let browser;
	try {
		browser = await chromium.launch({ headless: true });
		await runSmoke(browser);
	} finally {
		if (browser)
			await browser.close().catch(() => {});
	}
}

/* --no-server or FWLIVE_HARNESS_URL: use an already-running harness (no local spawn). */
const direct = process.argv.includes('--no-server') || !!EXTERNAL_URL;
(direct ? mainDirect() : mainWithServer()).catch((e) => {
	console.error(e);
	process.exit(1);
});

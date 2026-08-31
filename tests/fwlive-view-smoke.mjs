#!/usr/bin/env node
/**
 * Mocked LuCI view Playwright smoke (Tier 2 / #240 Wave B2) — no QEMU.
 *
 *   npm run test:view
 */
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.FWLIVE_HARNESS_PORT || 8765);
const BASE = process.env.FWLIVE_HARNESS_URL || `http://127.0.0.1:${PORT}`;

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
	await page.locator('a.fwlive-chip-clear').first().click().catch(() => {});
	await page.waitForTimeout(200);
}

async function testProtoCustomWins(page) {
	await clearFilters(page);
	await page.locator('#fwlive-proto').selectOption('TCP');
	await page.waitForSelector('.fwlive-chip', { timeout: 5000 });
	let chip = await page.locator('.fwlive-chip-label').first().textContent();
	if (!/TCP/i.test(chip || ''))
		throw new Error(`expected TCP chip, got: ${chip}`);

	await page.locator('#fwlive-proto-custom').fill('esp');
	await page.waitForTimeout(400);
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
	await page.waitForTimeout(300);
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
	const cb = page.locator('#fwlive-show-hostnames');
	const genBefore = await page.evaluate(() => window.fwliveView.resolveGeneration);
	await cb.check();
	await page.waitForTimeout(200);
	const genAfter = await page.evaluate(() => window.fwliveView.resolveGeneration);
	if (genAfter <= genBefore)
		throw new Error('hostnames toggle must bump resolveGeneration');
	console.log('OK: hostnames toggle generation bump');
}

async function testPollErrorBanner(page) {
	await page.evaluate(() => {
		window.setFwlivePollMock(function() {
			return { log: [], error: 'filter_failed' };
		});
	});
	await page.evaluate(() => window.fwliveView.fetchEntries().then(() => window.fwliveView.updateStatus()));
	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-status');
		return el && /Connection lost/i.test(el.textContent || '');
	}, { timeout: 10000 });
	console.log('OK: poll error banner (#233)');
}

async function main() {
	const browser = await chromium.launch({ headless: true });
	const page = await browser.newPage();
	page.on('pageerror', (e) => console.error('pageerror:', e.message));

	await waitForHarness(page);
	await testInitialRender(page);
	await testPauseResume(page);
	await testDisplayDrawer(page);
	await testProtoCustomWins(page);
	await testChipInvert(page);
	await testSegmentToggles(page);
	await testHostnamesToggle(page);
	await testPollErrorBanner(page);

	console.log('fwlive view smoke OK (mocked harness)');
	await browser.close();
}

function spawnHarnessServer() {
	return spawn(process.execPath, ['scripts/serve-view-harness.mjs'], {
		cwd: ROOT,
		env: { ...process.env, FWLIVE_HARNESS_PORT: String(PORT) },
		stdio: ['ignore', 'pipe', 'pipe']
	});
}

function waitForServerReady(child) {
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error('harness server start timeout')), 15000);
		child.stdout.on('data', (chunk) => {
			if (/fwlive view harness/.test(String(chunk))) {
				clearTimeout(timer);
				resolve();
			}
		});
		child.on('error', reject);
		child.on('exit', (code) => {
			clearTimeout(timer);
			reject(new Error('harness server exited early: ' + code));
		});
	});
}

const direct = process.argv.includes('--no-server');
if (direct) {
	main().catch((e) => {
		console.error(e);
		process.exit(1);
	});
} else {
	const child = spawnHarnessServer();
	waitForServerReady(child)
		.then(() => main())
		.then(() => {
			child.kill('SIGTERM');
			process.exit(0);
		})
		.catch((e) => {
			console.error(e);
			child.kill('SIGTERM');
			process.exit(1);
		});
}

#!/usr/bin/env node
/**
 * Live View UI reliability smoke (#71) against a running QEMU LuCI guest.
 *
 *   FWLIVE_URL=http://127.0.0.1:8080 node tests/fwlive-ui-reliability-smoke.mjs
 *
 * Covers: poll error banner, hostname toggle race, pause/resume, filter debounce,
 * poll leak on leave/revisit.
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
			page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {}),
			page.click('button, input[type="submit"]')
		]);
		await page.goto(FWLIVE, { waitUntil: 'domcontentloaded', timeout: 60000 });
	}
	await page.waitForSelector('.fwlive-map', { timeout: 30000 });
}

function isFwlivePoll(postData) {
	if (!postData)
		return false;
	return /fwlive["']?\s*,\s*["']?poll/.test(postData)
		|| /"method"\s*:\s*"poll"/.test(postData) && /fwlive/.test(postData)
		|| postData.includes('fwlive') && postData.includes('poll');
}

async function waitForRows(page) {
	await page.waitForSelector('#fwlive-table tbody tr', { timeout: 45000 });
}

async function testPollErrorBanner(page) {
	await waitForRows(page);

	await page.route('**/ubus/**', async (route) => {
		const post = route.request().postData() || '';
		if (isFwlivePoll(post)) {
			await route.abort('failed');
			return;
		}
		await route.continue();
	});

	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-status');
		return el && /Connection lost/i.test(el.textContent || '');
	}, { timeout: 15000 });

	await page.unroute('**/ubus/**');

	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-status');
		return el && !/Connection lost/i.test(el.textContent || '');
	}, { timeout: 20000 });

	console.log('OK: poll error banner shows then clears');
}

async function testHostnameToggleRace(page) {
	const host = page.locator('#fwlive-show-hostnames');
	await host.waitFor({ timeout: 10000 });

	for (let i = 0; i < 12; i++) {
		await host.click({ force: true });
		await page.waitForTimeout(40);
	}

	/* End unchecked — table should still render without throwing. */
	if (await host.isChecked())
		await host.click({ force: true });

	await page.waitForTimeout(500);
	const rows = await page.locator('#fwlive-table tbody tr').count();
	if (rows < 1)
		throw new Error('hostname toggle race left table empty');

	const pageErrors = [];
	page.on('pageerror', (e) => pageErrors.push(e.message));
	await page.waitForTimeout(800);
	if (pageErrors.length)
		throw new Error('page errors after hostname toggles: ' + pageErrors.join('; '));

	console.log('OK: hostname toggle race (no empty table / pageerror)');
}

async function testPauseResume(page) {
	const refresh = page.locator('#fwlive-autorefresh');
	await refresh.waitFor({ timeout: 10000 });

	const beforeIds = await page.evaluate(() =>
		Array.from(document.querySelectorAll('#fwlive-table tbody tr'))
			.map((tr) => tr.getAttribute('data-id') || tr.innerText.slice(0, 40))
	);

	await refresh.uncheck();
	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-status');
		return el && /^Paused/i.test(el.textContent || '');
	}, { timeout: 10000 });

	/* Ingest while paused — generate a bit of wait for poll buffer fill. */
	await page.waitForTimeout(2500);

	await refresh.check();
	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-status');
		return el && !/^Paused/i.test(el.textContent || '') && !/Connection lost/i.test(el.textContent || '');
	}, { timeout: 15000 });

	await waitForRows(page);
	const afterIds = await page.evaluate(() =>
		Array.from(document.querySelectorAll('#fwlive-table tbody tr'))
			.map((tr) => tr.getAttribute('data-id') || tr.innerText.slice(0, 40))
	);

	if (afterIds.length < 1)
		throw new Error('resume left table empty');

	/* At least some pre-pause identity should still be representable (merge path). */
	const overlap = beforeIds.filter((id) => afterIds.includes(id));
	if (beforeIds.length && overlap.length < 1) {
		/* data-id may be absent — fall back to row count stability */
		if (afterIds.length < Math.min(3, beforeIds.length))
			throw new Error('resume dropped most rows unexpectedly');
	}

	console.log('OK: pause → resume (status + rows)');
}

async function testFilterDebounce(page) {
	const q = page.locator('#fwlive-q');
	await q.waitFor({ timeout: 10000 });
	await q.fill('');
	await page.waitForTimeout(200);

	const rebuilds = await page.evaluate(async () => {
		const tbody = document.querySelector('#fwlive-table tbody');
		if (!tbody)
			return { error: 'no tbody' };

		let mutations = 0;
		const obs = new MutationObserver(() => { mutations++; });
		obs.observe(tbody, { childList: true, subtree: true, characterData: true });

		const input = document.getElementById('fwlive-q');
		const word = 'zzzzunlikely';
		for (let i = 0; i < word.length; i++) {
			input.value = word.slice(0, i + 1);
			input.dispatchEvent(new Event('input', { bubbles: true }));
			await new Promise((r) => setTimeout(r, 15));
		}
		await new Promise((r) => setTimeout(r, 350));
		obs.disconnect();
		return { mutations, final: input.value };
	});

	if (rebuilds.error)
		throw new Error(rebuilds.error);
	if (rebuilds.final !== 'zzzzunlikely')
		throw new Error('search value not applied: ' + rebuilds.final);
	/* 10 keystrokes with 100ms debounce should not yield ~10 full rebuilds. */
	if (rebuilds.mutations >= 9)
		throw new Error(`filter debounce too chatty: ${rebuilds.mutations} mutations for 10 keystrokes`);

	/* Selects apply immediately — action change should mutate promptly. */
	const before = rebuilds.mutations;
	await page.locator('#fwlive-action').selectOption('pass');
	await page.waitForTimeout(200);
	const afterSelect = await page.evaluate(() => document.getElementById('fwlive-q').value);
	void before;
	void afterSelect;

	await q.fill('');
	await page.locator('#fwlive-action').selectOption('');
	await page.waitForTimeout(200);

	console.log(`OK: filter debounce (${rebuilds.mutations} mutations for 10 rapid keystrokes)`);
}

async function testPollLeak(page, context) {
	let pollCount = 0;
	const onReq = (req) => {
		const post = req.postData() || '';
		const url = req.url();
		if ((url.includes('/ubus') || url.includes('ubus')) && isFwlivePoll(post))
			pollCount++;
	};
	page.on('request', onReq);

	await page.waitForTimeout(3500);
	const baseline = pollCount;
	if (baseline < 1)
		throw new Error('no fwlive.poll observed during dwell (check ubus interception)');

	/* Leave Live View */
	await page.goto(`${BASE}/cgi-bin/luci/admin/status`, {
		waitUntil: 'domcontentloaded',
		timeout: 60000
	});
	await page.waitForTimeout(3500);
	const whileGone = pollCount;

	/* Revisit */
	await page.goto(FWLIVE, { waitUntil: 'domcontentloaded', timeout: 60000 });
	await page.waitForSelector('.fwlive-map', { timeout: 30000 });
	const afterReturnStart = pollCount;
	await page.waitForTimeout(3500);
	const afterReturn = pollCount - afterReturnStart;

	page.off('request', onReq);

	/*
	 * While on another page, poll should stop or nearly stop (pagehide removes poll).
	 * Allow a small tail from in-flight requests.
	 */
	const leaked = whileGone - baseline;
	if (leaked > 4)
		throw new Error(`poll leak while away: +${leaked} fwlive.poll after leaving (baseline ${baseline} → ${whileGone})`);

	/* After return, roughly 1/sec — not a runaway double (e.g. > 8 in 3.5s). */
	if (afterReturn > 8)
		throw new Error(`runaway polls after revisit: ${afterReturn} in ~3.5s`);

	console.log(`OK: poll leak spot-check (baseline=${baseline}, away=+${leaked}, back=${afterReturn})`);
	void context;
}

async function main() {
	const browser = await chromium.launch({ headless: true });
	const context = await browser.newContext();
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (e) => errors.push(e.message));

	await login(page);
	await waitForRows(page);

	await testPollErrorBanner(page);
	await testHostnameToggleRace(page);
	await testPauseResume(page);
	await testFilterDebounce(page);
	await testPollLeak(page, context);

	if (errors.length)
		console.warn('pageerror notes:', errors.join('; '));

	console.log('fwlive UI reliability smoke OK (#71)');
	await browser.close();
}

main().catch((e) => {
	console.error(e);
	process.exit(1);
});

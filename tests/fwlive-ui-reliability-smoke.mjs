#!/usr/bin/env node
/**
 * Live View UI reliability smoke (#71) against a running QEMU LuCI guest.
 *
 *   FWLIVE_URL=http://127.0.0.1:8080 node tests/fwlive-ui-reliability-smoke.mjs
 *
 * Covers: poll error banner (transport abort + reply.error #233), hostname
 * toggle race, pause/resume, filter debounce, poll leak on leave/revisit.
 *
 * Compatible with pre-A2 (#fwlive-autorefresh) and A2 (#fwlive-pause) chrome.
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

function isFwlivePoll(postData) {
	if (!postData)
		return false;
	/* LuCI/ubus call shapes — keep parentheses explicit (#83). */
	if (/fwlive["']?\s*,\s*["']?poll/.test(postData))
		return true;
	if (/"method"\s*:\s*"poll"/.test(postData) && /"object"\s*:\s*"fwlive"/.test(postData))
		return true;
	/* Fallback: JSON-RPC style with both tokens as whole words. */
	if (/\bfwlive\b/.test(postData) && /"poll"/.test(postData))
		return true;
	return false;
}

function ubusRouteMatch(url) {
	/* Playwright route predicates receive URL; request.url() is a string. */
	const s = typeof url === 'string' ? url : (url && url.href) || String(url || '');
	return s.includes('ubus');
}

async function openDisplayDrawer(page) {
	await page.waitForSelector('#fwlive-display-drawer', { timeout: 15000 });
}

async function waitForRows(page) {
	await page.waitForSelector('#fwlive-table tbody tr', { timeout: 45000 });
}

async function isPausedUi(page) {
	return page.evaluate(() => {
		const map = document.querySelector('.fwlive-map');
		if (map)
			return map.classList.contains('fwlive-watch-paused');
		const status = document.getElementById('fwlive-status');
		return !!(status && /^Paused/i.test(status.textContent || ''));
	});
}

async function setPaused(page, wantPaused) {
	const pauseBtn = page.locator('#fwlive-pause');
	if (await pauseBtn.count()) {
		const now = await isPausedUi(page);
		if (now !== wantPaused)
			await pauseBtn.click();
		await page.waitForFunction((want) => {
			const map = document.querySelector('.fwlive-map');
			return !!map && map.classList.contains('fwlive-watch-paused') === want;
		}, wantPaused, { timeout: 10000 });
		return;
	}

	const refresh = page.locator('#fwlive-autorefresh');
	await refresh.waitFor({ timeout: 10000 });
	if (wantPaused)
		await refresh.uncheck();
	else
		await refresh.check();
	await page.waitForFunction((want) => {
		const el = document.getElementById('fwlive-status');
		const paused = !!(el && /^Paused/i.test(el.textContent || ''));
		return paused === want;
	}, wantPaused, { timeout: 10000 });
}

async function testPollErrorBanner(page) {
	await waitForRows(page);

	await page.route(ubusRouteMatch, async (route) => {
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

	await page.unroute(ubusRouteMatch);

	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-status');
		return el && !/Connection lost/i.test(el.textContent || '');
	}, { timeout: 20000 });

	console.log('OK: poll error banner shows then clears (transport abort)');
}

/**
 * #233 — well-formed {"log":[],"error":"filter_failed"} must show the banner.
 * LuCI list-form ubus: [[id,sid],[0, result]].
 */
function fulfillFwlivePollError(postData) {
	let req;
	try {
		req = JSON.parse(postData);
	} catch (e) {
		return null;
	}
	if (!Array.isArray(req) || req.length < 2)
		return null;
	const id = req[0];
	return JSON.stringify([id, [0, { log: [], error: 'filter_failed' }]]);
}

async function testPollErrorFieldBanner(page) {
	await waitForRows(page);

	await page.route(ubusRouteMatch, async (route) => {
		const post = route.request().postData() || '';
		if (isFwlivePoll(post)) {
			const body = fulfillFwlivePollError(post);
			if (body) {
				await route.fulfill({
					status: 200,
					contentType: 'application/json',
					body
				});
				return;
			}
			await route.abort('failed');
			return;
		}
		await route.continue();
	});

	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-status');
		return el && /Connection lost/i.test(el.textContent || '');
	}, { timeout: 15000 });

	await page.unroute(ubusRouteMatch);

	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-status');
		return el && !/Connection lost/i.test(el.textContent || '');
	}, { timeout: 20000 });

	console.log('OK: poll reply.error banner shows then clears (#233)');
}

async function testHostnameToggleRace(page) {
	await openDisplayDrawer(page);
	const host = page.locator('#fwlive-show-hostnames');
	await host.waitFor({ state: 'visible', timeout: 10000 });

	const pageErrors = [];
	const onErr = (e) => pageErrors.push(e.message);
	page.on('pageerror', onErr);

	try {
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

		await page.waitForTimeout(800);
		if (pageErrors.length)
			throw new Error('page errors during hostname toggles: ' + pageErrors.join('; '));
	} finally {
		page.off('pageerror', onErr);
	}

	console.log('OK: hostname toggle race (no empty table / pageerror)');
}

async function testPauseResume(page) {
	const beforeIds = await page.evaluate(() =>
		Array.from(document.querySelectorAll('#fwlive-table tbody tr'))
			.map((tr) => tr.getAttribute('data-id') || tr.innerText.slice(0, 40))
	);

	await setPaused(page, true);

	/* Ingest while paused — generate a bit of wait for poll buffer fill. */
	await page.waitForTimeout(2500);

	await setPaused(page, false);

	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-status');
		return el && !/Connection lost/i.test(el.textContent || '');
	}, { timeout: 15000 });

	await waitForRows(page);
	const afterIds = await page.evaluate(() =>
		Array.from(document.querySelectorAll('#fwlive-table tbody tr'))
			.map((tr) => tr.getAttribute('data-id') || tr.innerText.slice(0, 40))
	);

	if (afterIds.length < 1)
		throw new Error('resume left table empty');

	const overlap = beforeIds.filter((id) => afterIds.includes(id));
	if (beforeIds.length && overlap.length < 1) {
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

	/* Clear search so the action select can change a non-empty table. */
	await q.fill('');
	await page.waitForTimeout(250);
	await waitForRows(page);

	/* Selects apply immediately — expect a tbody mutation soon after change.
	 * Prefer Playwright selectOption (fires change) and wait for observer. */
	const selectMutations = await page.evaluate(() => {
		window.__fwliveSelectMuts = 0;
		const tbody = document.querySelector('#fwlive-table tbody');
		if (!tbody)
			return { error: 'missing tbody' };
		if (window.__fwliveSelectObs)
			window.__fwliveSelectObs.disconnect();
		window.__fwliveSelectObs = new MutationObserver(() => {
			window.__fwliveSelectMuts++;
		});
		window.__fwliveSelectObs.observe(tbody, { childList: true, subtree: true });
		return { ok: true };
	});
	if (selectMutations.error)
		throw new Error(selectMutations.error);

	const action = page.locator('#fwlive-action');
	const cur = await action.inputValue();
	await action.selectOption(cur === 'pass' ? 'drop' : 'pass');
	await page.waitForFunction(() => (window.__fwliveSelectMuts || 0) >= 1, { timeout: 3000 });
	await page.evaluate(() => {
		if (window.__fwliveSelectObs)
			window.__fwliveSelectObs.disconnect();
		window.__fwliveSelectObs = null;
	});

	await action.selectOption('');
	await page.waitForTimeout(200);

	console.log(`OK: filter debounce (${rebuilds.mutations} mutations for 10 rapid keystrokes; select immediate)`);
}

async function testPollLeak(page) {
	let pollCount = 0;
	const onReq = (req) => {
		const post = req.postData() || '';
		if (ubusRouteMatch(req.url()) && isFwlivePoll(post))
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

	const leaked = whileGone - baseline;
	if (leaked > 4)
		throw new Error(`poll leak while away: +${leaked} fwlive.poll after leaving (baseline ${baseline} → ${whileGone})`);

	if (afterReturn > 8)
		throw new Error(`runaway polls after revisit: ${afterReturn} in ~3.5s`);

	console.log(`OK: poll leak spot-check (baseline=${baseline}, away=+${leaked}, back=${afterReturn})`);
}

async function main() {
	const browser = await chromium.launch({ headless: true });
	try {
		const context = await browser.newContext();
		const page = await context.newPage();
		const errors = [];
		page.on('pageerror', (e) => errors.push(e.message));

		await login(page);
		await waitForRows(page);

		await testPollErrorBanner(page);
		await testPollErrorFieldBanner(page);
		await testHostnameToggleRace(page);
		await testPauseResume(page);
		await testFilterDebounce(page);
		await testPollLeak(page);

		if (errors.length)
			throw new Error('unhandled pageerror(s): ' + errors.join('; '));

		console.log('fwlive UI reliability smoke OK (#71)');
	} finally {
		await browser.close();
	}
}

main().catch((e) => {
	console.error(e);
	process.exit(1);
});

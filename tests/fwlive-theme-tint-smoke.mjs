#!/usr/bin/env node
/**
 * Lab overlay smoke: assert Row tint paints a visible background under the active LuCI theme.
 * Used by scripts/qemu-theme-tint-smoke.sh (bootstrap + material). Not published-feed purity.
 *
 *   FWLIVE_URL=http://127.0.0.1:8080 node tests/fwlive-theme-tint-smoke.mjs
 */
import { chromium } from 'playwright';

const BASE = process.env.FWLIVE_URL || 'http://127.0.0.1:8080';
const THEME = process.env.FWLIVE_THEME_LABEL || 'unknown';
const MIN_DELTA = Number(process.env.FWLIVE_TINT_MIN_DELTA || 8);

async function login(page) {
	await page.goto(`${BASE}/cgi-bin/luci/admin/status/fwlive`, {
		waitUntil: 'networkidle',
		timeout: 60000
	});
	if (await page.locator('input[name="luci_username"]').count()) {
		await page.fill('input[name="luci_username"]', 'root');
		const pw = page.locator('input[name="luci_password"]');
		if (await pw.count())
			await pw.fill('');
		await page.click('button, input[type="submit"]');
		await page.waitForTimeout(1500);
		await page.goto(`${BASE}/cgi-bin/luci/admin/status/fwlive`, {
			waitUntil: 'networkidle',
			timeout: 60000
		});
	}
}

async function ensureTintOn(page) {
	const tint = page.locator('#fwlive-row-tint');
	await tint.waitFor({ timeout: 15000 });
	if (!(await tint.isChecked()))
		await tint.check();
}

async function measureTintDelta(page) {
	return page.evaluate((minDelta) => {
		const body = document.querySelector('#fwlive-table tbody');
		if (!body)
			return { ok: false, reason: 'no tbody' };

		let tr = body.querySelector('tr:not(.fwlive-row-alt)');
		if (!tr)
			tr = body.querySelector('tr');
		if (!tr)
			return { ok: false, reason: 'no rows' };

		const td = tr.querySelector('td');
		if (!td)
			return { ok: false, reason: 'no td' };

		const hadPass = tr.classList.contains('fwlive-row-pass');
		const hadDeny = tr.classList.contains('fwlive-row-deny');
		const probeClass = hadDeny ? 'fwlive-row-deny' : 'fwlive-row-pass';

		tr.classList.remove('fwlive-row-pass', 'fwlive-row-deny');
		const offBg = getComputedStyle(td).backgroundColor;
		tr.classList.add(probeClass);
		const onBg = getComputedStyle(td).backgroundColor;

		tr.classList.remove('fwlive-row-pass', 'fwlive-row-deny');
		if (hadPass)
			tr.classList.add('fwlive-row-pass');
		if (hadDeny)
			tr.classList.add('fwlive-row-deny');

		const parse = (value) => {
			const s = String(value || '').trim().toLowerCase();
			if (!s || s === 'transparent' || s === 'rgba(0, 0, 0, 0)' || s === 'rgba(0,0,0,0)')
				return null;
			const rgb = s.match(/rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)/i);
			if (rgb)
				return [parseFloat(rgb[1]), parseFloat(rgb[2]), parseFloat(rgb[3])];
			const modern = s.match(/color\(\s*srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)/i);
			if (modern)
				return [parseFloat(modern[1]) * 255, parseFloat(modern[2]) * 255, parseFloat(modern[3]) * 255];
			return null;
		};
		const a = parse(onBg);
		const b = parse(offBg);
		let delta = 0;
		if (!a && !b)
			delta = 0;
		else if (!a && b)
			delta = Math.abs(b[0]) + Math.abs(b[1]) + Math.abs(b[2]);
		else if (a && !b)
			delta = Math.abs(a[0]) + Math.abs(a[1]) + Math.abs(a[2]);
		else
			delta = Math.abs(a[0] - b[0]) + Math.abs(a[1] - b[1]) + Math.abs(a[2] - b[2]);

		const map = document.querySelector('.fwlive-map');
		const passToken = map
			? getComputedStyle(map).getPropertyValue('--fwlive-pass-color').trim()
			: '';
		const fallback = map ? map.getAttribute('data-tint-fallback') === '1' : false;

		return {
			ok: delta >= minDelta,
			delta,
			minDelta,
			onBg,
			offBg,
			passToken,
			fallback,
			reason: delta >= minDelta ? '' : `paint delta ${delta} < ${minDelta}`
		};
	}, MIN_DELTA);
}

async function main() {
	const browser = await chromium.launch({ headless: true });
	const page = await browser.newPage();
	page.on('pageerror', (e) => console.error('pageerror:', e.message));

	await login(page);
	await page.waitForSelector('#fwlive-table', { timeout: 30000 });
	await ensureTintOn(page);

	/* Wait for at least one row (log pipeline / synthetic traffic). */
	await page.waitForSelector('#fwlive-table tbody tr', { timeout: 45000 });
	/* Allow deferred paint probe (rAF) to finish before asserting. */
	await page.waitForTimeout(800);

	const result = await measureTintDelta(page);
	await browser.close();

	if (!result.ok) {
		console.error(`theme tint smoke FAIL (${THEME}): ${result.reason}`);
		console.error(JSON.stringify(result, null, 2));
		process.exit(1);
	}

	if (result.fallback) {
		console.error(`theme tint smoke FAIL (${THEME}): unexpected data-tint-fallback (CSS should paint without JS fallback)`);
		console.error(JSON.stringify(result, null, 2));
		process.exit(1);
	}

	console.log(`theme tint smoke OK (${THEME}): delta=${result.delta}`);
}

main().catch((e) => {
	console.error(e);
	process.exit(1);
});

#!/usr/bin/env node
/**
 * Lab overlay smoke: assert Row tint and zebra stripe paint under the active LuCI theme.
 * Used by scripts/qemu-theme-tint-smoke.sh (bootstrap + material). Not published-feed purity.
 *
 *   FWLIVE_URL=http://127.0.0.1:8080 node tests/fwlive-theme-tint-smoke.mjs
 *
 * Row tint: checkbox (#fwlive-row-tint-toggle) + palette select when on
 * (classic | accessible). Default classic is green/red.
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

async function openDisplayDrawer(page) {
	await page.waitForSelector('#fwlive-display-drawer', { timeout: 15000 });
}

async function tintIsOn(page) {
	const cb = page.locator('#fwlive-row-tint-toggle');
	return cb.isChecked();
}

async function setTintMode(page, mode) {
	await openDisplayDrawer(page);
	const cb = page.locator('#fwlive-row-tint-toggle');
	await cb.waitFor({ state: 'visible', timeout: 15000 });

	if (mode === 'off') {
		if (await tintIsOn(page))
			await cb.uncheck();
		await page.waitForFunction(() => {
			const map = document.querySelector('.fwlive-map');
			const toggle = document.getElementById('fwlive-row-tint-toggle');
			return map
				&& map.getAttribute('data-row-tint') === 'off'
				&& toggle
				&& !toggle.checked;
		}, { timeout: 5000 });
		return;
	}

	if (!(await tintIsOn(page)))
		await cb.check();

	const tint = page.locator('#fwlive-row-tint');
	await tint.waitFor({ state: 'visible', timeout: 5000 });
	const tag = await tint.evaluate((el) => el.tagName);
	if (tag !== 'SELECT')
		throw new Error(`#fwlive-row-tint must be a <select>, got <${tag}>`);
	await tint.selectOption(mode);
	await page.waitForFunction((want) => {
		const map = document.querySelector('.fwlive-map');
		return map && map.getAttribute('data-row-tint') === want;
	}, mode, { timeout: 5000 });
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
		const mode = map ? map.getAttribute('data-row-tint') : '';
		const fallback = map ? map.getAttribute('data-tint-fallback') === '1' : false;

		return {
			ok: delta >= minDelta,
			delta,
			minDelta,
			onBg,
			offBg,
			passToken,
			mode,
			fallback,
			reason: delta >= minDelta ? '' : `paint delta ${delta} < ${minDelta}`
		};
	}, MIN_DELTA);
}

async function measureZebraDelta(page) {
	return page.evaluate((minDelta) => {
		const body = document.querySelector('#fwlive-table tbody');
		if (!body)
			return { ok: false, reason: 'no tbody' };

		const alt = body.querySelector('tr.fwlive-row-alt');
		const plain = body.querySelector('tr:not(.fwlive-row-alt)');
		if (!alt || !plain)
			return { ok: false, reason: 'need both alt and non-alt rows' };

		const altTd = alt.querySelector('td');
		const plainTd = plain.querySelector('td');
		if (!altTd || !plainTd)
			return { ok: false, reason: 'missing td' };

		const altBg = getComputedStyle(altTd).backgroundColor;
		const plainBg = getComputedStyle(plainTd).backgroundColor;

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
		const a = parse(altBg);
		const b = parse(plainBg);
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
		const bgToken = map
			? getComputedStyle(map).getPropertyValue('--fwlive-bg-medium').trim()
			: '';

		return {
			ok: delta >= minDelta,
			delta,
			minDelta,
			altBg,
			plainBg,
			bgToken,
			reason: delta >= minDelta ? '' : `zebra paint delta ${delta} < ${minDelta}`
		};
	}, MIN_DELTA);
}

async function assertModePaint(page, mode) {
	await setTintMode(page, mode);
	await page.waitForTimeout(800);
	const result = await measureTintDelta(page);
	if (!result.ok) {
		console.error(`theme tint smoke FAIL (${THEME}/${mode}): ${result.reason}`);
		console.error(JSON.stringify(result, null, 2));
		process.exit(1);
	}
	if (result.mode !== mode) {
		console.error(`theme tint smoke FAIL (${THEME}/${mode}): data-row-tint=${result.mode}`);
		process.exit(1);
	}
	/* Fallback is allowed on themes that break color-mix; paint delta must still pass. */
	return result;
}

async function main() {
	const browser = await chromium.launch({ headless: true });
	const page = await browser.newPage();
	page.on('pageerror', (e) => console.error('pageerror:', e.message));

	await login(page);
	await page.waitForSelector('#fwlive-table', { timeout: 30000 });
	await openDisplayDrawer(page);
	await page.waitForSelector('#fwlive-row-tint-toggle', { timeout: 15000 });

	/* Wait for at least two rows so zebra alt + non-alt both exist. */
	await page.waitForFunction(() => {
		const rows = document.querySelectorAll('#fwlive-table tbody tr');
		return rows.length >= 2
			&& document.querySelector('tr.fwlive-row-alt')
			&& document.querySelector('tr:not(.fwlive-row-alt)');
	}, { timeout: 45000 });

	/* Zebra first with row tint off (isolates alternating stripe from pass/deny). */
	await setTintMode(page, 'off');
	await page.waitForTimeout(400);
	const zebra = await measureZebraDelta(page);
	if (!zebra.ok) {
		await browser.close();
		console.error(`theme zebra smoke FAIL (${THEME}): ${zebra.reason}`);
		console.error(JSON.stringify(zebra, null, 2));
		process.exit(1);
	}

	const classic = await assertModePaint(page, 'classic');
	const accessible = await assertModePaint(page, 'accessible');

	await browser.close();

	console.log(
		`theme tint smoke OK (${THEME}): zebraDelta=${zebra.delta}`
		+ ` classicDelta=${classic.delta} classicFallback=${classic.fallback}`
		+ ` accessibleDelta=${accessible.delta} accessibleFallback=${accessible.fallback}`
	);
}

main().catch((e) => {
	console.error(e);
	process.exit(1);
});

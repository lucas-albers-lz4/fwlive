#!/usr/bin/env node
// Optional installed LuCI disclosure smoke; RPC failure states are injected.
// FWLIVE_URL=http://127.0.0.1:8080 node tests/fwlive-rules-diagnostics-lab.mjs
import { chromium } from 'playwright';
import { loginFwlive } from './lib/playwright-lab.mjs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';

const output = process.env.FWLIVE_RULES_DETAILS_OUT || await mkdtemp(path.join(os.tmpdir(), 'fwlive-rules-details-'));
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true });
const results = [];
try {
	for (const mobile of [false, true]) {
		const context = await browser.newContext({ viewport: mobile ? { width: 390, height: 844 } : { width: 1280, height: 900 }, hasTouch: mobile, isMobile: mobile });
		const page = await context.newPage();
		const errors = [];
		page.on('pageerror', error => errors.push(String(error)));
		await loginFwlive(page);
		await page.waitForSelector('#fwlive-table');
		await page.waitForLoadState('networkidle');
		// Keep initial page errors in the report; the assertion below covers
		// errors introduced by the diagnostic-state interactions being exercised.
		const startupPageErrors = errors.splice(0);
		assert.equal(await page.locator('#fwlive-rules-details').isVisible(), false, 'healthy installed lookup hides details');
		const initialWidth = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth }));
		// Use the installed LuCI module. Injection models independent RPC outcomes;
		// it is not evidence of an installed combined backend failure.
		await page.evaluate(async () => {
			const view = await L.require('view.status.fwlive');
			window.reviewView = view;
			view.rulesMapTruncated = true;
			view.lastRulesError = 'mktemp_failed';
			view.updateBackendUi();
		});
		const details = page.locator('#fwlive-rules-details');
		const summary = details.locator('summary');
		assert.equal(await details.isVisible(), true);
		assert.equal(await details.getAttribute('open'), null);
		if (mobile) await summary.tap();
		else {
			await summary.focus();
			await page.keyboard.press('Enter');
		}
		await page.waitForFunction(() => document.getElementById('fwlive-rules-details').open);
		const body = await page.locator('#fwlive-rules-details-body').innerText();
		assert.match(body, /truncated=true/);
		assert.match(body, /mktemp_failed/);
		assert.match(body, /does not change your firewall rules/);
		assert.match(body, /Searching by a friendly rule name may miss/);
		const finalWidth = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth }));
		assert.ok(finalWidth.scroll <= initialWidth.scroll, 'details must not add horizontal page overflow');
		await page.screenshot({ path: output + (mobile ? '/mobile.png' : '/desktop.png'), fullPage: true });
		await page.evaluate(() => {
			reviewView.lastRulesError = '<svg/onload=PWNED>';
			reviewView.updateBackendUi();
		});
		const textOnly = await page.locator('#fwlive-rules-details-body').evaluate(body => body.childNodes.length === 1 && body.firstChild.nodeType === Node.TEXT_NODE && body.textContent.includes('<svg/onload=PWNED>') && !body.querySelector('svg'));
		assert.equal(textOnly, true);
		await page.evaluate(() => {
			reviewView.rulesMapTruncated = false;
			reviewView.lastRulesError = null;
			reviewView.updateBackendUi();
		});
		assert.equal(await details.isVisible(), false);
		assert.equal(await details.getAttribute('open'), null);
		assert.deepEqual(errors, []);
		results.push({ viewport: mobile ? '390x844, touch' : '1280x900, keyboard', healthyHidden: true, combinedDiagnostics: true, textNodes: true, recoveryHidden: true, initialWidth, finalWidth, startupPageErrors, diagnosticPageErrors: errors });
		await context.close();
	}
	await writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2) + '\n', { mode: 0o600 });
	console.log(JSON.stringify(results, null, 2));
} finally {
	await browser.close();
}

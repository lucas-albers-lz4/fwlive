#!/usr/bin/env node
/**
 * Lab Playwright bundle (Wave C2 / #240): one Chromium, one login, three smokes.
 *
 *   FWLIVE_URL=http://127.0.0.1:8080 node tests/fwlive-lab-playwright-bundle.mjs
 *
 * Sequence (same context): chip-invert → proto-ui → ui-reliability.
 * theme-tint and i18n-spotcheck stay separate (theme / lang session switches).
 */
import { gotoFwlive, launchLabBrowser, loginFwlive, waitForFwliveMap } from './lib/playwright-lab.mjs';
import { runChipInvertSmoke } from './fwlive-chip-invert-smoke.mjs';
import { runProtoUiSmoke } from './fwlive-proto-ui-smoke.mjs';
import { runUiReliabilitySmoke } from './fwlive-ui-reliability-smoke.mjs';

async function main() {
	const { browser, page } = await launchLabBrowser();
	try {
		await loginFwlive(page);

		console.log('== chip invert ==');
		await runChipInvertSmoke(page);

		await gotoFwlive(page);
		await waitForFwliveMap(page);
		console.log('== proto UI ==');
		await runProtoUiSmoke(page);

		await gotoFwlive(page);
		await waitForFwliveMap(page);
		console.log('== UI reliability ==');
		await runUiReliabilitySmoke(page);

		console.log('fwlive lab Playwright bundle OK');
	} finally {
		await browser.close();
	}
}

main().catch((e) => {
	console.error(e);
	process.exit(1);
});

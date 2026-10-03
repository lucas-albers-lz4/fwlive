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

async function requireControl(page, selector) {
	const loc = page.locator(selector);
	if (await loc.count() !== 1)
		throw new Error(`required control missing: ${selector}`);
	return loc;
}

async function requireSegmentButtons(page) {
	return {
		simple: await requireControl(page, '#fwlive-view-simple'),
		detail: await requireControl(page, '#fwlive-view-detail'),
		wrap: await requireControl(page, '#fwlive-msg-wrap'),
		oneline: await requireControl(page, '#fwlive-msg-oneline')
	};
}

async function testInitialRender(page) {
	const rows = await page.locator('#fwlive-table tbody tr').count();
	if (rows < 1)
		throw new Error('expected at least one table row after initial render');
	console.log('OK: initial render');
}

async function testPauseResume(page) {
	const pauseBtn = await requireControl(page, '#fwlive-pause');
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
	await page.evaluate(() => {
		const view = window.fwliveView;
		const original = view.invertFilter;
		window.__fwliveInvertCalls = 0;
		view.invertFilter = function() {
			window.__fwliveInvertCalls++;
			return original.apply(this, arguments);
		};
	});
	let invert = page.getByRole('button', { name: 'Exclude instead', exact: true });
	if (await invert.count() !== 1)
		throw new Error('include chip must expose an Exclude instead button');
	await invert.press('Enter');
	await page.waitForFunction(() => {
		const chip = document.querySelector('.fwlive-chip-label');
		return chip && /not pass/i.test(chip.textContent || '');
	}, { timeout: 5000 });
	const after = await page.locator('.fwlive-chip-label').first().textContent();
	if (before === after || !/not pass/i.test(after || ''))
		throw new Error(`chip invert failed: ${before} -> ${after}`);
	const firstCount = await page.evaluate(() => window.__fwliveInvertCalls);
	if (firstCount !== 1)
		throw new Error(`Enter must invert exactly once, got ${firstCount} calls`);
	invert = page.getByRole('button', { name: 'Include instead', exact: true });
	if (await invert.count() !== 1)
		throw new Error('excluded chip must expose an Include instead button');
	await invert.press('Space');
	await page.waitForFunction(() => {
		const chip = document.querySelector('.fwlive-chip-label');
		return chip && !/not pass/i.test(chip.textContent || '');
	}, { timeout: 5000 });
	const secondCount = await page.evaluate(() => window.__fwliveInvertCalls);
	if (secondCount !== 2)
		throw new Error(`Space must invert exactly once more, got ${secondCount} total calls`);
	if (await page.getByRole('button', { name: 'Exclude instead', exact: true }).count() !== 1)
		throw new Error('included chip must restore the Exclude instead accessible name');
	console.log('OK: chip accessible name and Enter/Space inversion');
}

async function ensureSimpleView(page) {
	const simple = await requireControl(page, '#fwlive-view-simple');
	if ((await simple.getAttribute('aria-pressed')) !== 'true') {
		await simple.click();
		await page.waitForFunction(
			() => {
				const el = document.getElementById('fwlive-view-simple');
				return el && el.getAttribute('aria-pressed') === 'true';
			},
			{ timeout: 5000 }
		);
	}
}

async function testSimpleActionLayout(page) {
	await clearFilters(page);
	await ensureSimpleView(page);

	const locales = [
		{
			name: 'en',
			translations: {},
			labels: ['pass', 'block', 'drop', 'reject']
		},
		{
			name: 'de',
			translations: {
				pass: 'erlaubt',
				block: 'blockiert',
				drop: 'verworfen',
				reject: 'abgelehnt'
			},
			labels: ['erlaubt', 'blockiert', 'verworfen', 'abgelehnt']
		},
		{
			name: 'ru',
			translations: {
				pass: 'разрешён',
				block: 'заблокирован',
				drop: 'отброшен',
				reject: 'отклонён'
			},
			labels: ['разрешён', 'заблокирован', 'отброшен', 'отклонён']
		}
	];
	const sizes = [
		{ name: 'narrow', width: 390 },
		{ name: 'desktop', width: 1280 }
	];
	const actions = ['pass', 'block', 'drop', 'reject'];
	const originalActions = await page.evaluate(() =>
		window.fwliveView.entries.map((entry) => entry.action)
	);

	try {
		for (const locale of locales) {
			const expectedLabels = await page.evaluate(({ locale, actions }) => {
				const view = window.fwliveView;
				window.fwliveTestTranslations = locale.translations;
				/* Change the render key before repaint so each locale rebuilds its labels. */
				view.entries.forEach((entry) => (entry.action = 'unknown'));
				view.invalidateFilteredRows();
				view.renderRows(true);
				const expected = {};
				view.entries.forEach((entry, index) => {
					const action = actions[index % actions.length];
					entry.action = action;
					expected[String(entry.id)] = locale.labels[index % actions.length];
				});
				view.invalidateFilteredRows();
				view.renderRows(true);
				return expected;
			}, { locale, actions });

			for (const fontSize of [13, 16]) {
				for (const size of sizes) {
					await page.setViewportSize({ width: size.width, height: 1000 });
					const geometry = await page.evaluate(
						({ fontSize }) => {
							const view = window.fwliveView;
						const map = document.querySelector('.fwlive-map');
						map.style.fontSize = fontSize + 'px';

						const box = (element) => {
							const rect = element.getBoundingClientRect();
							return {
								left: rect.left,
								right: rect.right,
								top: rect.top,
								bottom: rect.bottom,
								width: rect.width,
								height: rect.height
							};
						};
						const table = document.getElementById('fwlive-table');
						const scroll = document.getElementById('fwlive-scroll');
						const rows = Array.from(table.querySelectorAll('tbody tr'))
							.filter((row) => row.querySelector('td.fwlive-action'))
						const cells = rows.map((row) => {
							const action = row.querySelector('td.fwlive-action');
							const link = action.querySelector('a.fwlive-filter-link');
							const button = action.querySelector('button.fwlive-row-expand');
							const time = row.querySelector('td.fwlive-time');
							const range = document.createRange();
							range.selectNodeContents(time);
							const timeText = range.getBoundingClientRect();
							return {
								rowId: button && button._fwliveRowId,
								label: link && link.textContent.trim(),
								action: box(action),
								link: box(link),
								button: box(button),
								time: box(time),
								timeText: {
									left: timeText.left,
									right: timeText.right,
									top: timeText.top,
									bottom: timeText.bottom
								},
								actionScrollWidth: action.scrollWidth,
								actionClientWidth: action.clientWidth,
								timeScrollWidth: time.scrollWidth,
								timeClientWidth: time.clientWidth
							};
						});
						const timeTitle = rows[0].querySelector('td.fwlive-time').getAttribute('title');
						return {
							cells,
							viewportWidth: window.innerWidth,
							scrollWidth: scroll.scrollWidth,
							scrollClientWidth: scroll.clientWidth,
							actionColumnWidth: parseFloat(
								getComputedStyle(table.querySelector('col.fwlive-col-action')).width
							),
							mapFontSize: parseFloat(getComputedStyle(map).fontSize),
							hint: document.querySelector('.fwlive-hint-line').textContent,
							timeTitle,
							help: document.querySelector('#fwlive-help').textContent
						};
						},
						{ fontSize }
					);

					if (geometry.cells.length !== originalActions.length)
						throw new Error(`expected every fixture action row for ${locale.name}`);
					if (geometry.actionColumnWidth < geometry.mapFontSize * 11.5 - 1)
						throw new Error(
							`shipped CSS action column too narrow at ${locale.name}/${fontSize}px/${size.name}: ${geometry.actionColumnWidth}px`
						);
					for (const cell of geometry.cells) {
						if (cell.label !== expectedLabels[cell.rowId])
							throw new Error(
								`wrong ${locale.name} action label for ${cell.rowId}: expected ${expectedLabels[cell.rowId]}, got ${cell.label}`
							);
						if (
							cell.actionScrollWidth > cell.actionClientWidth ||
							cell.timeScrollWidth > cell.timeClientWidth ||
							cell.link.left < cell.action.left ||
							cell.link.right > cell.action.right ||
							cell.button.right > cell.action.right ||
							cell.button.left < cell.link.right ||
							cell.button.right > cell.timeText.left ||
							cell.timeText.left < cell.time.left ||
							cell.timeText.right > cell.time.right ||
							cell.button.width < 24 ||
							cell.button.height < 24
						)
							throw new Error(
								`localized Action/Time geometry failed at ${locale.name}/${fontSize}px/${size.name}: ${JSON.stringify(cell)}`
							);
					}
					if (
						!geometry.timeTitle.includes('message button') ||
						!geometry.timeTitle.includes('click a row') ||
						!geometry.hint.includes('message button') ||
						!geometry.hint.includes('click a row') ||
						!geometry.help.includes('message button') ||
						!geometry.help.includes('click a row')
					)
						throw new Error('Simple-view message instructions disagree or omit a control');
					if (size.name === 'narrow' && geometry.scrollWidth <= geometry.scrollClientWidth)
						throw new Error(
							`narrow Simple view must keep the table horizontally scrollable: ${JSON.stringify(geometry)}`
						);
				}
			}
		}
	} finally {
		await page.evaluate((actions) => {
			window.fwliveTestTranslations = {};
			window.fwliveView.entries.forEach((entry) => (entry.action = 'unknown'));
			window.fwliveView.invalidateFilteredRows();
			window.fwliveView.renderRows(true);
			window.fwliveView.entries.forEach((entry, index) => {
				entry.action = actions[index];
			});
			window.fwliveView.invalidateFilteredRows();
			document.querySelector('.fwlive-map').style.removeProperty('font-size');
			window.fwliveView.renderRows(true);
		}, originalActions);
		await page.setViewportSize({ width: 1280, height: 720 });
	}
	console.log('OK: Simple Action/Time geometry for en/de/ru at 13px/16px narrow/desktop widths');
}

async function expansionButtonByRowId(page, rowId, name) {
	const buttons = page.locator('button.fwlive-row-expand');
	const index = await buttons.evaluateAll(
		(nodes, wanted) => nodes.findIndex((button) => button._fwliveRowId === wanted),
		rowId
	);
	if (index < 0) throw new Error(`Simple-view expansion button missing for ${rowId}`);
	const named = page.getByRole('button', { name, exact: true });
	if ((await named.count()) <= index)
		throw new Error(`button ${rowId} is not exposed as ${name}`);
	return named.nth(index);
}

async function isFocused(locator) {
	return locator.evaluate((element) => element === document.activeElement);
}

async function testSimpleExpansionKeyboard(page) {
	await clearFilters(page);
	await ensureSimpleView(page);
	await page.evaluate(() => {
		const view = window.fwliveView;
		const original = view.onRowClick;
		window.__fwliveRowClickCalls = 0;
		view.onRowClick = function () {
			window.__fwliveRowClickCalls++;
			return original.apply(this, arguments);
		};
	});

	const structure = await page.locator('#fwlive-table').evaluate((table) => {
		const row = table.querySelector('tbody tr');
		const button = row && row.querySelector('button.fwlive-row-expand');
		return {
			table: table.tagName,
			head: table.querySelector('thead th') && table.querySelector('thead th').tagName,
			row: row && row.tagName,
			rowRole: row && row.getAttribute('role'),
			rowTabindex: row && row.getAttribute('tabindex'),
			button: button && button.tagName,
			buttonCell: button && button.closest('td') && button.closest('td').tagName,
			rowExpansionRoles: table.querySelectorAll('tbody tr[role]').length
		};
	});
	if (
		structure.table !== 'TABLE' ||
		structure.head !== 'TH' ||
		structure.row !== 'TR' ||
		structure.rowRole !== null ||
		structure.rowTabindex !== null ||
		structure.button !== 'BUTTON' ||
		structure.buttonCell !== 'TD' ||
		structure.rowExpansionRoles !== 0
	)
		throw new Error(
			`expansion must preserve native table semantics: ${JSON.stringify(structure)}`
		);

	const link = page.locator('#fwlive-table tbody tr a.fwlive-filter-link').first();
	await link.click();
	await page.waitForSelector('.fwlive-chip', { timeout: 5000 });
	const linkState = await page.evaluate(() => ({
		expanded: window.fwliveView.expandedRowId,
		panels: document.querySelectorAll('#fwlive-table tbody tr.fwlive-msg-expand').length
	}));
	if (linkState.expanded !== null || linkState.panels !== 0)
		throw new Error(
			`filter-link clicks must not also expand rows: ${JSON.stringify(linkState)}`
		);
	await clearFilters(page);

	const firstRowId = await page
		.locator('button.fwlive-row-expand')
		.first()
		.evaluate((button) => button._fwliveRowId);
	let clicks = await page.evaluate(() => window.__fwliveRowClickCalls);
	await page.locator('#fwlive-table tbody tr').first().locator('td.fwlive-time').click();
	await page.waitForFunction((id) => window.fwliveView.expandedRowId === id, firstRowId);
	let afterMouseOpen = await page.evaluate(() => window.__fwliveRowClickCalls);
	if (afterMouseOpen !== clicks + 1)
		throw new Error(`existing row click must toggle once, got ${afterMouseOpen - clicks}`);
	clicks = afterMouseOpen;
	await page.locator('#fwlive-table tbody tr').first().locator('td.fwlive-time').click();
	await page.waitForFunction(() => window.fwliveView.expandedRowId === null);
	const afterMouseClose = await page.evaluate(() => window.__fwliveRowClickCalls);
	if (afterMouseClose !== clicks + 1)
		throw new Error(`second row click must collapse once, got ${afterMouseClose - clicks}`);

	const targetId = 'log:5';
	let show = await expansionButtonByRowId(page, targetId, 'Show full message');
	const actionLink = show.locator('xpath=ancestor::tr').locator('a.fwlive-filter-link').first();
	if ((await actionLink.count()) !== 1)
		throw new Error('target row must retain its action filter link');
	await actionLink.focus();
	await page.keyboard.press('Tab');
	if (!(await isFocused(show)))
		throw new Error('Tab from the action filter link must reach the message button');

	clicks = await page.evaluate(() => window.__fwliveRowClickCalls);
	await show.press('Enter');
	await page.waitForFunction((id) => window.fwliveView.expandedRowId === id, targetId);
	const afterEnter = await page.evaluate(() => window.__fwliveRowClickCalls);
	if (afterEnter !== clicks + 1)
		throw new Error(`Enter must expand exactly once, got ${afterEnter - clicks}`);
	let hide = page.getByRole('button', { name: 'Hide full message', exact: true });
	if ((await hide.count()) !== 1 || !(await isFocused(hide)))
		throw new Error('expanded control must update its accessible name and retain focus');
	const expanded = await page.evaluate(() => {
		const button = document.activeElement;
		const id = button && button.getAttribute('aria-controls');
		const panel = id && document.getElementById(id);
		return {
			label: button && button.getAttribute('aria-label'),
			expanded: button && button.getAttribute('aria-expanded'),
			controls: id,
			panelTag: panel && panel.tagName,
			panelText: panel && panel.textContent,
			images: panel ? panel.querySelectorAll('img').length : -1,
			rowId: button && button._fwliveRowId
		};
	});
	if (
		expanded.label !== 'Hide full message' ||
		expanded.expanded !== 'true' ||
		expanded.controls !== 'fwlive-expanded-message' ||
		expanded.panelTag !== 'PRE' ||
		expanded.rowId !== targetId ||
		!String(expanded.panelText).includes('<img src=x onerror=alert(1)>') ||
		expanded.images !== 0
	)
		throw new Error(`expanded panel association/text failed: ${JSON.stringify(expanded)}`);

	clicks = afterEnter;
	await hide.press('Space');
	await page.waitForFunction(() => window.fwliveView.expandedRowId === null);
	const afterSpace = await page.evaluate(() => window.__fwliveRowClickCalls);
	if (afterSpace !== clicks + 1)
		throw new Error(`Space must collapse exactly once, got ${afterSpace - clicks}`);
	show = await expansionButtonByRowId(page, targetId, 'Show full message');
	if (!(await isFocused(show)) || (await page.locator('#fwlive-expanded-message').count()))
		throw new Error('collapsed control must keep focus and remove its panel association');

	clicks = afterSpace;
	await show.press('Enter');
	await page.waitForFunction((id) => window.fwliveView.expandedRowId === id, targetId);
	hide = page.getByRole('button', { name: 'Hide full message', exact: true });
	await page.evaluate((id) => {
		const view = window.fwliveView;
		window.__fwliveOldExpandButton = document.activeElement;
		const row = view.entries.find((entry) => String(entry.id) === id);
		if (!row) throw new Error('target row missing before same-row refresh');
		row.message += ' refreshed-keyed-row';
		view.invalidateFilteredRows();
		view.renderRows(true);
	}, targetId);
	const refreshFocus = await page.evaluate(() => ({
		oldConnected: window.__fwliveOldExpandButton.isConnected,
		sameNode: document.activeElement === window.__fwliveOldExpandButton,
		rowId: document.activeElement && document.activeElement._fwliveRowId,
		panelText: document.getElementById('fwlive-expanded-message')?.textContent || ''
	}));
	if (
		refreshFocus.oldConnected ||
		refreshFocus.sameNode ||
		refreshFocus.rowId !== targetId ||
		!refreshFocus.panelText.includes('refreshed-keyed-row') ||
		!(await isFocused(hide))
	)
		throw new Error(
			`same-row keyed rebuild must restore focus and updated message: ${JSON.stringify(refreshFocus)}`
		);

	await page.evaluate(() => {
		const view = window.fwliveView;
		view.entries.reverse();
		view.invalidateFilteredRows();
		view.renderRows(true);
	});
	const reorderedFocus = await page.evaluate(() => {
		const button = document.activeElement;
		const row = button && button.closest('tr');
		return {
			rowId: button && button._fwliveRowId,
			focused: !!(button && button.classList.contains('fwlive-row-expand')),
			panelImmediatelyFollows: !!(
				row &&
				row.nextElementSibling &&
				row.nextElementSibling.classList.contains('fwlive-msg-expand')
			)
		};
	});
	if (
		reorderedFocus.rowId !== targetId ||
		!reorderedFocus.focused ||
		!reorderedFocus.panelImmediatelyFollows
	)
		throw new Error(
			`reordered row must keep disclosure focus and association: ${JSON.stringify(reorderedFocus)}`
		);

	await page.evaluate(() => {
		const view = window.fwliveView;
		const query = document.getElementById('fwlive-q');
		query.value = 'u2-filter-no-match';
		view.invalidateFilteredRows();
		view.renderRows(true);
	});
	const filteredOut = await page.evaluate(() => ({
		button: Array.from(document.querySelectorAll('button.fwlive-row-expand')).some(
			(node) => node._fwliveRowId === 'log:5'
		),
		panel: !!document.getElementById('fwlive-expanded-message'),
		oldConnected: !window.__fwliveOldExpandButton.isConnected,
		focusedExpander: !!document.activeElement.closest?.('button.fwlive-row-expand')
	}));
	if (
		filteredOut.button ||
		filteredOut.panel ||
		!filteredOut.oldConnected ||
		filteredOut.focusedExpander
	)
		throw new Error(
			`filtering must remove the row and stale focus target: ${JSON.stringify(filteredOut)}`
		);
	await page.evaluate(() => {
		const view = window.fwliveView;
		document.getElementById('fwlive-q').value = '';
		view.expandedRowId = null;
		view.invalidateFilteredRows();
		view.renderRows(true);
	});

	const removable = await expansionButtonByRowId(page, targetId, 'Show full message');
	await removable.focus();
	await page.evaluate((id) => {
		const view = window.fwliveView;
		view.entries = view.entries.filter((entry) => String(entry.id) !== id);
		view.invalidateFilteredRows();
		view.renderRows(true);
	}, targetId);
	if (
		await page
			.locator('button.fwlive-row-expand')
			.evaluateAll((nodes) => nodes.some((button) => button._fwliveRowId === 'log:5'))
	)
		throw new Error('removing a row must remove its expansion control');

	const remaining = page.locator('button.fwlive-row-expand').first();
	await remaining.focus();
	await page.evaluate(() => window.fwliveView.setViewMode('detailed'));
	await page.waitForFunction(() => window.fwliveView.viewMode === 'detailed');
	const detail = await page.evaluate(() => ({
		controls: document.querySelectorAll('button.fwlive-row-expand').length,
		panels: document.querySelectorAll('#fwlive-table tbody tr.fwlive-msg-expand').length,
		rows: document.querySelectorAll('#fwlive-table tbody tr').length,
		messageCells: document.querySelectorAll('#fwlive-table tbody td.fwlive-message').length,
		rowRoles: document.querySelectorAll('#fwlive-table tbody tr[role]').length
	}));
	if (detail.controls || detail.panels || !detail.rows || !detail.messageCells || detail.rowRoles)
		throw new Error(
			`Detail view must remain native and keep message columns: ${JSON.stringify(detail)}`
		);
	await page.evaluate(() => window.fwliveView.setViewMode('simple'));
	await page.waitForFunction(() => window.fwliveView.viewMode === 'simple');
	console.log(
		'OK: Simple message button tab order, keyboard, focus, association, filtering and table semantics'
	);
}

async function testSegmentToggles(page) {
	const { detail, oneline } = await requireSegmentButtons(page);
	await detail.click();
	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-view-detail');
		return el && el.getAttribute('aria-pressed') === 'true';
	}, { timeout: 5000 });

	await oneline.click();
	await page.waitForFunction(() => {
		const el = document.getElementById('fwlive-msg-oneline');
		return el && el.getAttribute('aria-pressed') === 'true';
	}, { timeout: 5000 });
	console.log('OK: segment aria-pressed toggles');
}

async function ensureDetailedOneLine(page) {
	const { detail, oneline } = await requireSegmentButtons(page);
	if (await detail.getAttribute('aria-pressed') !== 'true') {
		await detail.click();
		await page.waitForFunction(() => {
			const el = document.getElementById('fwlive-view-detail');
			return el && el.getAttribute('aria-pressed') === 'true';
		}, { timeout: 5000 });
	}

	if (await oneline.getAttribute('aria-pressed') !== 'true') {
		await oneline.click();
		await page.waitForFunction(() => {
			const el = document.getElementById('fwlive-msg-oneline');
			return el && el.getAttribute('aria-pressed') === 'true';
		}, { timeout: 5000 });
	}
}

async function testFixtureRowsAndTextSafety(page) {
	await clearFilters(page);
	await ensureDetailedOneLine(page);
	await page.waitForFunction(() =>
		document.querySelectorAll('#fwlive-table tbody tr').length >= 6,
		{ timeout: 10000 }
	);
	const result = await page.evaluate(() => {
		const table = document.getElementById('fwlive-table');
		const addressCells = table ? Array.from(table.querySelectorAll('td.fwlive-addr'))
			.map((cell) => cell.textContent || '') : [];
		return {
			text: table ? table.textContent || '' : '',
			addressCells,
			images: table ? table.querySelectorAll('img').length : 0,
			ansi: table ? (table.textContent || '').indexOf('\u001b[31mDROP\u001b[0m') >= 0 : false
		};
	});
	if (!result.addressCells.some((text) => text.includes('2001:db8::1')) ||
		!result.addressCells.some((text) => text.includes('2001:db8::2')))
		throw new Error('IPv6 fixture must remain visible in source/destination address cells');
	if (!result.text.includes('<img src=x onerror=alert(1)>'))
		throw new Error('hostile message fixture must remain visible as text');
	if (!result.text.includes('x'.repeat(320)))
		throw new Error('overlong one-line message must remain available in full');
	if (!result.ansi)
		throw new Error('ANSI message fixture must remain visible without interpretation');
	if (result.images !== 0)
		throw new Error('hostile message fixture must not create an img element');
	console.log('OK: IPv6, one-line, ANSI, overlong, and hostile-row fixtures');
}

async function testHostnamesToggle(page) {
	await clearFilters(page);
	/* Simple view so filteredRows() still has the canned log IPs. */
	const simple = await requireControl(page, '#fwlive-view-simple');
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
			return el && /could not read the firewall log/i.test(el.textContent || '');
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

async function testAdaptiveSummaryAndWarnings(page) {
	try {
		await page.evaluate(async () => {
			window.__fwlivePrevPollMock = window.setFwlivePollMock(async function() {
				await new Promise((resolve) => setTimeout(resolve, 1600));
				return {
					log: [{
						id: 99,
						time: 1704067299,
						msg: 'fw4: DROP IN=wan SRC=2001:db8::99 DST=2001:db8::100 PROTO=TCP'
					}],
					adaptive: 1,
					effective_limit: 25,
					messages_received: 1,
					truncated: 1,
					shed: { level: 'hot', limit: 25 },
					summary: {
						top_talkers: [{ value: '<img src=x onerror=alert(1)>', count: 1 }],
						top_drops: [{ value: '2001:db8::99', count: 1 }],
						top_rules: [{ value: '<summary-rule>', count: 1 }]
					}
				};
			});
			await window.fwliveView.fetchEntries();
		});
		await page.waitForFunction(() => {
			const view = window.fwliveView;
			const card = document.getElementById('fwlive-summary');
			return view && view.summaryMode && card && card.style.display === 'block';
		}, { timeout: 10000 });
		const banner = await page.locator('#fwlive-adaptive').textContent();
		const summary = await page.locator('#fwlive-summary-body').textContent();
		if (!/Server limited fetch/i.test(banner || '') || !/25/.test(banner || ''))
			throw new Error(`adaptive shedding banner missing: ${banner}`);
		if (!String(summary).includes('<img src=x onerror=alert(1)>') ||
			!String(summary).includes('2001:db8::99'))
			throw new Error(`summary fixture missing expected text: ${summary}`);
		if (await page.locator('#fwlive-summary-body img').count())
			throw new Error('summary values must remain text nodes');

		await page.evaluate(() => {
			const view = window.fwliveView;
			window.__fwliveWarningState = {
				loggingStatus: view.loggingStatus,
				firewallBackend: view.firewallBackend,
				lastRulesError: view.lastRulesError,
				lastPollError: view.lastPollError,
				lastPollErrorCode: view.lastPollErrorCode
			};
			view.loggingStatus = Object.assign({}, view.loggingStatus, {
				warnings: ['legacy_iptables_detected']
			});
			view.firewallBackend = 'nft';
			view.lastRulesError = null;
			view.lastPollError = false;
			view.updateBackendUi();
			view.updateStatus();
		});
		const warnings = await page.locator('#fwlive-backend').textContent();
		const healthyStatus = await page.locator('#fwlive-status').textContent();
		if (/timeout/i.test(warnings || '') || !/legacy iptables table/i.test(warnings || ''))
			throw new Error(`warning rendering missing: ${warnings}`);
		if (/is incomplete/i.test(healthyStatus || ''))
			throw new Error(`healthy poll must not show an installation error: ${healthyStatus}`);

		await page.evaluate(() => {
			const view = window.fwliveView;
			view.lastPollError = true;
			view.lastPollErrorCode = 'jsonfilter_missing';
			view.updateBackendUi();
			view.updateStatus();
		});
		const installError = await page.locator('#fwlive-status').textContent();
		if (installError !== 'Installation is incomplete. Reinstall luci-app-fwlive.')
			throw new Error(`missing jsonfilter must show only the concise repair line: ${installError}`);
		const backendContext = await page.locator('#fwlive-backend').textContent();
		if (!/using fw4/i.test(backendContext || '') || /timeout/i.test(backendContext || ''))
			throw new Error(`missing jsonfilter must preserve backend context without a second diagnosis: ${backendContext}`);

		await page.evaluate(() => {
			const view = window.fwliveView;
			view.lastPollError = false;
			view.lastPollErrorCode = null;
			view.updateBackendUi();
			view.updateStatus();
		});
		const recoveredBackend = await page.locator('#fwlive-backend').textContent();
		const recoveredStatus = await page.locator('#fwlive-status').textContent();
		if (!/using fw4/i.test(recoveredBackend || '') || /timeout/i.test(recoveredBackend || ''))
			throw new Error(`installation recovery must restore the backend label: ${recoveredBackend}`);
		if (/Installation is incomplete/i.test(recoveredStatus || ''))
			throw new Error(`installation recovery must clear the installation error: ${recoveredStatus}`);

		await page.evaluate(() => {
			const view = window.fwliveView;
			view.lastPollError = true;
			view.lastPollErrorCode = 'filter_failed';
			view.loggingStatus.warnings = ['legacy_iptables_detected'];
			view.updateStatus();
		});
		const ordinaryPollError = await page.locator('#fwlive-status').textContent();
		if (!/could not read the firewall log/i.test(ordinaryPollError || ''))
			throw new Error(`typed poll errors must show the router-read message: ${ordinaryPollError}`);
		if (/Installation is incomplete/i.test(ordinaryPollError || ''))
			throw new Error(`a logging warning must not replace the typed poll diagnosis: ${ordinaryPollError}`);
		console.log('OK: adaptive summary, shedding, and warning rendering');
	} finally {
		await page.evaluate(() => {
			if (typeof window.__fwlivePrevPollMock !== 'undefined') {
				window.setFwlivePollMock(window.__fwlivePrevPollMock);
				delete window.__fwlivePrevPollMock;
			}
			const view = window.fwliveView;
			const state = window.__fwliveWarningState;
			view.loggingStatus = state.loggingStatus;
			view.firewallBackend = state.firewallBackend;
			view.lastRulesError = state.lastRulesError;
			view.lastPollError = state.lastPollError;
			view.lastPollErrorCode = state.lastPollErrorCode;
			delete window.__fwliveWarningState;
			view.updateBackendUi();
			view.updateStatus();
			view.leaveSummaryMode();
		});
	}
}

async function testStorageFailure(page) {
	/* No-throw smoke: save* swallow storage denial; no visible fallback exists. */
	const completed = await page.evaluate(() => {
		const proto = Storage.prototype;
		const desc = Object.getOwnPropertyDescriptor(proto, 'setItem');
		Object.defineProperty(proto, 'setItem', {
			configurable: true,
			value: function() { throw new Error('storage denied'); }
		});
		try {
			const view = window.fwliveView;
			view.saveViewMode();
			view.saveShowHostnames();
			view.saveRowTint();
			return true;
		} finally {
			Object.defineProperty(proto, 'setItem', desc);
		}
	});
	if (completed !== true)
		throw new Error('storage failure no-throw smoke: page.evaluate did not complete');
	await requireSegmentButtons(page);
	console.log('OK: storage failure no-throw smoke (best-effort; no visible fallback asserted)');
}

async function testResolverError(page) {
	try {
		await page.evaluate(async () => {
			const view = window.fwliveView;
			view.showHostnames = true;
			view.hostnameCache.clear();
			view.hostnameFailed.clear();
			view.resolveLoadShed = false;
			view.resolveShedUntil = 0;
			let reply = { names: {}, error: 'jshn_lib_missing' };
			window.__fwlivePrevResolveMock = window.setFwliveResolveMock(function() {
				return reply;
			});
			await view.resolveHostnamesForEntries([
				{ src: '2001:db8::1', dst: '2001:db8::2' }
			]);
			if (view.hostnameFailed.size !== 0)
				throw new Error('jshn_lib_missing must not enter the negative hostname cache');
			reply = 5;
			await view.resolveHostnamesForEntries([
				{ src: '2001:db8::1', dst: '2001:db8::2' }
			]);
		});
		const state = await page.evaluate(() => ({
			failed: window.fwliveView.hostnameFailed.size,
			shed: window.fwliveView.resolveLoadShed,
			inFlight: window.fwliveView.resolveInFlight
		}));
		if (state.failed !== 0 || state.shed || state.inFlight)
			throw new Error(`resolver error mutated hostname state: ${JSON.stringify(state)}`);
		console.log('OK: string and numeric resolver-error reply paths');
	} finally {
		await page.evaluate(() => {
			if (typeof window.__fwlivePrevResolveMock !== 'undefined') {
				window.setFwliveResolveMock(window.__fwlivePrevResolveMock);
				delete window.__fwlivePrevResolveMock;
			}
		});
	}
}

async function testRulesTruncatedDegraded(page) {
	/* Tier-2 Gap 1 (#274): a truncated rules reply degrades the backend span
	 * while the counter and paused class still render (~256-rules shape). */
	const pauseBtn = await requireControl(page, '#fwlive-pause');
	await pauseBtn.click();
	await page.waitForFunction(() => {
		const map = document.querySelector('.fwlive-map');
		return map && map.classList.contains('fwlive-watch-paused');
	}, { timeout: 10000 });
	try {
		await page.evaluate(async () => {
			window.__fwlivePrevRulesMock = window.setFwliveRulesMock(function() {
				return { backend: 'nft', rules: {}, truncated: true, error: 'mktemp_failed' };
			});
			await window.fwliveView.loadRulesMap();
			window.fwliveView.updateStatus();
		});
		await page.waitForFunction(() => {
			const el = document.getElementById('fwlive-backend');
			return el && /Some rule names may be missing/i.test(el.textContent || '');
		}, { timeout: 10000 });
		const status = await page.locator('#fwlive-status').textContent();
		if (!/matching/i.test(status || ''))
			throw new Error('counter must still render under map truncation, got: ' + status);
		const paused = await page.evaluate(() => {
			const map = document.querySelector('.fwlive-map');
			return !!(map && map.classList.contains('fwlive-watch-paused'));
		});
		if (!paused)
			throw new Error('paused class must survive map truncation');
		const details = page.locator('#fwlive-rules-details');
		const summary = details.locator('summary');
		if (await details.getAttribute('open') !== null)
			throw new Error('rule-name diagnostics must start collapsed');
		await summary.focus();
		await page.keyboard.press('Enter');
		await page.waitForFunction(() => document.getElementById('fwlive-rules-details').open);
		const diagnosis = await page.locator('#fwlive-rules-details-body').innerText();
		if (!diagnosis.includes('truncated=true') || !diagnosis.includes('mktemp_failed'))
			throw new Error('expanded diagnostics must expose both conditions: ' + diagnosis);
		await page.evaluate(() => window.fwliveView.updateBackendUi());
		if (await details.getAttribute('open') === null)
			throw new Error('routine updates must preserve an opened disclosure');
		await summary.click();
		await page.waitForFunction(() => !document.getElementById('fwlive-rules-details').open);
		await page.evaluate(async () => {
			window.setFwliveRulesMock(() => ({
				backend: 'nft', rules: {}, truncated: false, error: '<svg/onload=PWNED>'
			}));
			await window.fwliveView.loadRulesMap();
		});
		const textOnly = await page.locator('#fwlive-rules-details-body').evaluate(body =>
			body.childNodes.length === 1 && body.firstChild.nodeType === Node.TEXT_NODE &&
			body.textContent.includes('<svg/onload=PWNED>') && !body.querySelector('svg')
		);
		if (!textOnly) throw new Error('unknown diagnostic codes must render as literal text nodes');
		console.log('OK: combined rule-name diagnostics, keyboard disclosure, text nodes and counter/paused (#1038 #274)');
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
		await testFixtureRowsAndTextSafety(page);
		await testHostnamesToggle(page);
		await testPollErrorBanner(page);
		await testAdaptiveSummaryAndWarnings(page);
		await testStorageFailure(page);
		await testResolverError(page);
		await testRulesTruncatedDegraded(page);
		await testSimpleActionLayout(page);
		await testSimpleExpansionKeyboard(page);

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

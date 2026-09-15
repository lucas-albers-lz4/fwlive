#!/usr/bin/env node
/**
 * Layer 2 browser performance gate for #306 / #339.
 *
 * Runs against a real LuCI guest, but replaces only fwlive.poll with the
 * checked-in 2,000-entry fixture. This keeps the browser/UI path real while
 * making the load repeatable across guests.
 *
 * Example:
 *   FWLIVE_URL=http://127.0.0.1:8080 \
 *   FWLIVE_CPU_THROTTLE=4 \
 *   FWLIVE_SOAK_MS=1800000 \
 *   FWLIVE_PERF_ROW_LIMIT=500 \
 *   node tests/fwlive-layer2-performance.mjs
 *
 * Set FWLIVE_ENFORCE=1 to turn the visibility and performance targets into
 * process failures. Shorter soak values are useful for harness development;
 * only the default 30-minute run is suitable for #306 sign-off.
 * Set FWLIVE_PERF_REAL_POLL=1 for a supplemental run against the guest's real
 * log pipeline; that mode does not provide the 2,000-entry fixture workload.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { labBaseUrl, labFwliveUrl } from './lib/playwright-lab.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE_PATH = process.env.FWLIVE_PERF_FIXTURE ||
	path.join(ROOT, 'tests/fixtures/logread-2000.json');
const CPU_THROTTLE = Math.max(1, Number(process.env.FWLIVE_CPU_THROTTLE || 4));
const SOAK_MS_RAW = process.env.FWLIVE_SOAK_MS;
if (SOAK_MS_RAW !== undefined && !Number.isFinite(Number(SOAK_MS_RAW)))
	throw new Error(`FWLIVE_SOAK_MS must be numeric: ${SOAK_MS_RAW}`);
const SOAK_MS = SOAK_MS_RAW === undefined || SOAK_MS_RAW === ''
	? 30 * 60 * 1000
	: Math.max(1000, Number(SOAK_MS_RAW));
const ENFORCE = process.env.FWLIVE_ENFORCE === '1';
const REAL_POLL = process.env.FWLIVE_PERF_REAL_POLL === '1';
const POLL_DELAY_MS = Math.max(0, Number(process.env.FWLIVE_PERF_POLL_DELAY_MS || 0));
const WEAK_DEVICE = process.env.FWLIVE_PERF_WEAK_DEVICE === '1';
const PERF_ROW_LIMIT_RAW = process.env.FWLIVE_PERF_ROW_LIMIT;
const PERF_ROW_LIMIT = PERF_ROW_LIMIT_RAW === undefined || PERF_ROW_LIMIT_RAW === ''
	? 2000
	: Number(PERF_ROW_LIMIT_RAW);
const PERF_ROW_LIMIT_OPTIONS = [25, 50, 100, 250, 500, 1000, 2000];
if (!Number.isInteger(PERF_ROW_LIMIT) || !PERF_ROW_LIMIT_OPTIONS.includes(PERF_ROW_LIMIT))
	throw new Error(
		`FWLIVE_PERF_ROW_LIMIT must be one of ${PERF_ROW_LIMIT_OPTIONS.join(', ')}: ${PERF_ROW_LIMIT_RAW}`
	);

const fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));
if (!fixture || !Array.isArray(fixture.log) || fixture.log.length !== 2000)
	throw new Error(`performance fixture must contain exactly 2000 log entries: ${FIXTURE_PATH}`);

function isFwlivePoll(postData) {
	if (!postData) return false;
	let parsed;
	try {
		parsed = JSON.parse(postData);
	} catch (e) {
		return false;
	}
	const requests = Array.isArray(parsed) ? parsed : [parsed];
	return requests.some((req) => {
		const params = req && req.params;
		return !!(
			req &&
			typeof req === 'object' &&
			req.method === 'call' &&
			Array.isArray(params) &&
			params[1] === 'fwlive' &&
			params[2] === 'poll' &&
			typeof req.id !== 'undefined'
		);
	});
}

function pollPayload(pollNo) {
	/* One new firewall row per poll keeps the table hot without an artificial
	 * 2,000-new-rows-per-second flood. Change the newest raw entry so it stays
	 * inside the displayed sample after the table's row-limit slicing/reverse.
	 * The raw payload remains 2,000 entries. */
	const rows = fixture.log.map((row, index) => {
		if (index !== fixture.log.length - 1) return row;
		return { ...row, id: 1000000 + pollNo, time: row.time + pollNo };
	});
	const result = {
		...fixture,
		log: rows,
		adaptive: 1,
		messages_received: rows.length
	};
	return result;
}

function syntheticResult(req, payload) {
	const params = req && req.params;
	const object = Array.isArray(params) ? params[1] : '';
	const method = Array.isArray(params) ? params[2] : '';
	if (object === 'fwlive' && method === 'poll') return payload;
	if (object === 'fwlive' && method === 'rules') return { rules: {}, backend: 'nft' };
	if (object === 'fwlive' && method === 'logging_status') {
		return {
			wan_zone: 'wan',
			wan_log: false,
			wan_log_limit: null,
			nf_log_ipv4: false,
			nf_log_ipv6: false,
			ready: true,
			blockers: [],
			warnings: [],
			weak_device: WEAK_DEVICE
		};
	}
	if (object === 'uci' && method === 'changes') return {};
	return {};
}

async function installBrowserMetrics(page) {
	await page.addInitScript(() => {
		const state = {
			frameIntervals: [],
			paintAfterMutation: [],
			longTasks: [],
			tableMutations: []
		};
		window.__fwlivePerf = state;

		if (typeof PerformanceObserver === 'function') {
			try {
				const longTaskObserver = new PerformanceObserver((list) => {
					for (const entry of list.getEntries())
						state.longTasks.push({ start: entry.startTime, duration: entry.duration });
				});
				longTaskObserver.observe({ type: 'longtask', buffered: true });
				state.longTaskObserver = longTaskObserver;
			} catch (e) {
				/* Chromium supports longtask; leave the field empty elsewhere. */
			}
		}

		let previousFrame;
		const frame = (time) => {
			if (previousFrame !== undefined) state.frameIntervals.push(time - previousFrame);
			previousFrame = time;
			requestAnimationFrame(frame);
		};
		requestAnimationFrame(frame);

		const observer = new MutationObserver((records) => {
			let tableChanged = false;
			for (const record of records) {
				const target = record.target;
				if (target && target.closest && target.closest('#fwlive-table tbody')) {
					tableChanged = true;
					break;
				}
			}
			if (!tableChanged) return;
			const committed = performance.now();
			state.tableMutations.push(committed);
			requestAnimationFrame(() => {
				state.paintAfterMutation.push(performance.now() - committed);
			});
		});
		state.mutationObserver = observer;
		const observeDocument = () => {
			if (document.documentElement) {
				observer.observe(document.documentElement, { subtree: true, childList: true });
				return;
			}
			requestAnimationFrame(observeDocument);
		};
		observeDocument();
	});
}

function percentile(values, p) {
	if (!values.length) return null;
	const sorted = values.slice().sort((a, b) => a - b);
	const index = Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p));
	return Number(sorted[index].toFixed(2));
}

function summarize(values) {
	return {
		count: values.length,
		p50: percentile(values, 0.5),
		p95: percentile(values, 0.95),
		max: values.length ? Number(Math.max(...values).toFixed(2)) : null
	};
}

async function waitForPollCount(counts, target, timeoutMs) {
	const deadline = Date.now() + timeoutMs;
	while (counts.polls < target && Date.now() < deadline)
		await new Promise((resolve) => setTimeout(resolve, 50));
	return counts.polls >= target;
}

async function sampleHeapUsage(cdp, samples, forceGc) {
	if (forceGc) {
		try {
			await cdp.send('HeapProfiler.collectGarbage');
		} catch (e) {
			/* Runtime.getHeapUsage remains useful if forced GC is unavailable. */
		}
	}
	try {
		const usage = await cdp.send('Runtime.getHeapUsage');
		samples.push({
			t: Date.now(),
			usedBytes: Number(usage.usedSize),
			totalBytes: Number(usage.totalSize),
			forcedGc: !!forceGc
		});
	} catch (e) {
		/* Keep the report explicit if a non-Chromium CDP omits heap usage. */
	}
}

async function setVisibilityState(page, cdp, state) {
	try {
		await cdp.send('Emulation.setPageVisibilityState', { visibilityState: state });
		const observed = await page.evaluate(() => document.visibilityState);
		if (observed === state) return 'cdp';
	} catch (e) {
		/* Older Chromium builds do not expose this experimental command. */
	}
	await page.evaluate((next) => {
		Object.defineProperty(document, 'hidden', {
			configurable: true,
			get: () => next === 'hidden'
		});
		Object.defineProperty(document, 'visibilityState', {
			configurable: true,
			get: () => next
		});
		document.dispatchEvent(new Event('visibilitychange'));
	}, state);
	return 'document-emulation';
}

async function loginWithoutOpeningLiveView(page) {
	await page.goto(`${labBaseUrl()}/cgi-bin/luci/admin/status`, {
		waitUntil: 'domcontentloaded',
		timeout: 60000
	});
	if (!await page.locator('input[name="luci_username"]').count()) return;
	await page.fill('input[name="luci_username"]', 'root');
	const password = page.locator('input[name="luci_password"]');
	if (await password.count()) await password.fill('');
	await Promise.all([
		page.waitForURL(/\/cgi-bin\/luci/, { timeout: 30000 }).catch(() => {}),
		page.click('button, input[type="submit"]')
	]);
}

async function main() {
	const fixtureBase = { ...fixture, messages_received: fixture.log.length, adaptive: 1 };
	const browser = await chromium.launch({ headless: true });
	const context = await browser.newContext();
	const page = await context.newPage();
	const cdp = await context.newCDPSession(page);
	const counts = { polls: 0 };
	const pollStarts = new WeakMap();
	const pollRtts = [];
	const started = Date.now();

	page.on('pageerror', (e) => console.error('pageerror:', e.message));
	page.on('request', (request) => {
		if (!isFwlivePoll(request.postData() || '')) return;
		pollStarts.set(request, Date.now());
		if (REAL_POLL) counts.polls++;
	});
	page.on('response', (response) => {
		const request = response.request();
		if (!isFwlivePoll(request.postData() || '')) return;
		const t0 = pollStarts.get(request);
		if (t0 !== undefined) pollRtts.push(Date.now() - t0);
	});
	await installBrowserMetrics(page);
	await cdp.send('Emulation.setCPUThrottlingRate', { rate: CPU_THROTTLE });

	try {
		await loginWithoutOpeningLiveView(page);
		if (!REAL_POLL) await page.route('**/ubus**', async (route) => {
			const postData = route.request().postData() || '';
			if (!isFwlivePoll(postData)) {
				await route.continue();
				return;
			}
			counts.polls++;
			const parsed = JSON.parse(postData);
			const batched = Array.isArray(parsed);
			const requests = batched ? parsed : [parsed];
			const payload = pollPayload(counts.polls);
			const replies = requests.map((req) => ({
				jsonrpc: '2.0',
				id: req.id,
				result: [0, syntheticResult(req, payload)]
			}));
			if (POLL_DELAY_MS) await new Promise((resolve) => setTimeout(resolve, POLL_DELAY_MS));
			await route.fulfill({
				status: 200,
				contentType: 'application/json',
				body: JSON.stringify(batched ? replies : replies[0])
			});
		});
		await page.goto(labFwliveUrl(), {
			waitUntil: 'domcontentloaded',
			timeout: 60000
		});
		await page.waitForSelector('.fwlive-map', { timeout: 30000 });
		let displayRowLimit = Number(await page.locator('#fwlive-limit').inputValue());
		if (REAL_POLL) {
			await new Promise((resolve) => setTimeout(resolve, 3000));
		} else {
			await page.locator('#fwlive-limit').selectOption(String(PERF_ROW_LIMIT));
			displayRowLimit = PERF_ROW_LIMIT;
			await page.waitForFunction(
				(limit) =>
					document.querySelector('#fwlive-limit')?.value === String(limit) &&
					document.querySelectorAll('#fwlive-table tbody tr').length >= Math.min(limit, 100),
				PERF_ROW_LIMIT,
				{ timeout: 60000 }
			);
		}

		const visibleRows = await page.locator('#fwlive-table tbody tr').count();
		/* Let the poll that filled the table finish before taking the hidden-tab
		 * baseline; otherwise an already-dispatched request is miscounted. */
		await new Promise((resolve) => setTimeout(resolve, 1200));
		const initialPolls = counts.polls;
		if (!initialPolls) throw new Error('fixture poll was not observed');

		/* CDP visibility emulation exercises the actual visibilitychange handler. */
		const hiddenVisibilityMethod = await setVisibilityState(page, cdp, 'hidden');
		await new Promise((resolve) => setTimeout(resolve, 2500));
		const hiddenPolls = counts.polls - initialPolls;
		const visibleVisibilityMethod = await setVisibilityState(page, cdp, 'visible');
		const resumed = await waitForPollCount(counts, counts.polls + 1, 10000);

		const heapSamples = [];
		await sampleHeapUsage(cdp, heapSamples, true);
		const soakStarted = Date.now();
		while (Date.now() - soakStarted < SOAK_MS) {
			const remaining = SOAK_MS - (Date.now() - soakStarted);
			await new Promise((resolve) => setTimeout(resolve, Math.min(1000, remaining)));
			await sampleHeapUsage(cdp, heapSamples, false);
		}
		await sampleHeapUsage(cdp, heapSamples, true);

		const metrics = await page.evaluate(() => {
			const state = window.__fwlivePerf || {};
			if (state.longTaskObserver) state.longTaskObserver.disconnect();
			if (state.mutationObserver) state.mutationObserver.disconnect();
			return {
				frame: {
					count: (state.frameIntervals || []).length,
					maxIntervalMs: (state.frameIntervals || []).length
						? Number(Math.max(...state.frameIntervals).toFixed(2))
						: null
				},
				paintAfterMutation: state.paintAfterMutation || [],
				tableMutations: state.tableMutations || [],
				longTasks: state.longTasks || []
			};
		});

		const longTaskDurations = metrics.longTasks.map((entry) => entry.duration);
		const longTasksOver250Ms = longTaskDurations.filter((duration) => duration >= 250).length;
		const heapBytes = heapSamples.map((sample) => sample.usedBytes);
		const heapBaseline = heapBytes.length ? heapBytes[0] : null;
		const heapFinal = heapBytes.length ? heapBytes[heapBytes.length - 1] : null;
		const heapMax = heapBytes.length ? Math.max(...heapBytes) : null;
		const heapGrowthBytes = heapFinal === null || heapBaseline === null
			? null
			: heapFinal - heapBaseline;
		const heapPeakGrowthBytes = heapMax === null || heapBaseline === null
			? null
			: heapMax - heapBaseline;
		const report = {
			issue: 339,
			parent_issue: 306,
			substrate: 'real LuCI guest + Chromium Playwright',
			browser: await page.evaluate(() => navigator.userAgent),
			fixture: path.relative(ROOT, FIXTURE_PATH),
			poll_mode: REAL_POLL ? 'real-guest-log-pipeline' : 'fixture-intercepted',
			raw_payload_rows: REAL_POLL ? null : fixtureBase.log.length,
			display_row_limit: displayRowLimit,
			visible_rows: visibleRows,
			weak_device: WEAK_DEVICE,
			cpu_throttle_rate: CPU_THROTTLE,
			soak_ms: SOAK_MS,
			polls: counts.polls,
			poll_rtt_ms: summarize(pollRtts),
			visibility: {
				method: hiddenVisibilityMethod === visibleVisibilityMethod
					? hiddenVisibilityMethod
					: `${hiddenVisibilityMethod}->${visibleVisibilityMethod}`,
				initial_polls: initialPolls,
				hidden_polls_during_2500ms: hiddenPolls,
				resumed
			},
			frame: metrics.frame,
			render_commit_to_paint_ms: summarize(metrics.paintAfterMutation),
			table_mutation_count: metrics.tableMutations.length,
			summary_mode: await page.evaluate(() => {
				const el = document.getElementById('fwlive-summary');
				return !!el && el.style.display !== 'none';
			}),
			largest_main_thread_task_ms: longTaskDurations.length
				? Number(Math.max(...longTaskDurations).toFixed(2))
				: null,
			long_task_count: longTaskDurations.length,
			long_tasks_over_250ms: longTasksOver250Ms,
			heap: {
				measurement: 'CDP Runtime.getHeapUsage',
				samples: heapSamples.length,
				baseline_bytes: heapBaseline,
				final_bytes: heapFinal,
				max_sample_bytes: heapMax,
				growth_bytes: heapGrowthBytes,
				growth_mb: heapGrowthBytes === null ? null : Number((heapGrowthBytes / 1048576).toFixed(2)),
				peak_sample_growth_bytes: heapPeakGrowthBytes,
				peak_sample_growth_mb: heapPeakGrowthBytes === null
					? null
					: Number((heapPeakGrowthBytes / 1048576).toFixed(2))
			},
			started_at: new Date(started).toISOString(),
			finished_at: new Date().toISOString()
		};

		console.log(JSON.stringify(report, null, 2));
		if (ENFORCE) {
			const renderMax = report.render_commit_to_paint_ms.max;
			const heapGrowth = report.heap.growth_mb;
			if (!report.visibility.resumed || report.visibility.hidden_polls_during_2500ms > 0)
				throw new Error(`visibility gate failed: ${JSON.stringify(report.visibility)}`);
			if (renderMax !== null && renderMax >= 250)
				throw new Error(`render commit-to-paint target failed: ${renderMax} ms`);
			if (heapGrowth !== null && heapGrowth >= 50)
				throw new Error(`heap growth target failed: ${heapGrowth} MiB`);
		}
	} finally {
		await browser.close();
	}
}

main().catch((e) => {
	console.error(e);
	process.exit(1);
});

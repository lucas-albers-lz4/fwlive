#!/usr/bin/env node
/*
 * Keep one real LuCI fwlive viewer open while the routed forwarding probe
 * runs.  The process is deliberately separate from the traffic probe so the
 * latter can own the endpoint namespaces and report only network metrics.
 */
import fs from 'node:fs';
import path from 'node:path';
import {
	fwliveMethodRequestIds,
	fwliveRpcReplyForRequest,
	isSuccessfulFwliveRpcReply
} from './lib/fwlive-perf-rpc.mjs';

const args = process.argv.slice(2);
let readyFile = process.env.FWLIVE_SLO_VIEWER_READY_FILE || '';
let startFile = process.env.FWLIVE_SLO_VIEWER_START_FILE || '';
let stopFile = process.env.FWLIVE_SLO_VIEWER_STOP_FILE || '';
let resultFile = process.env.FWLIVE_SLO_VIEWER_RESULT_FILE || '';
let timeoutMs = Number(process.env.FWLIVE_SLO_VIEWER_TIMEOUT_MS || 120000);
let drainMs = Number(process.env.FWLIVE_SLO_VIEWER_DRAIN_MS || 3000);

function usage() {
	console.log(`Usage: ${process.argv[1]} --ready-file PATH --start-file PATH --stop-file PATH --result-file PATH [options]

Options:
  --timeout-ms N   maximum wait after --start-file (default: 120000)
  --drain-ms N     wait for in-flight requests after --stop-file (default: 3000)
  -h, --help       show this help`);
}

function fail(message) {
	throw new Error(`forwarding-slo-viewer: ${message}`);
}

function takeValue(option, index) {
	if (index + 1 >= args.length || !args[index + 1]) fail(`${option} needs a value`);
	return args[index + 1];
}

for (let i = 0; i < args.length; i++) {
	switch (args[i]) {
		case '--ready-file':
			readyFile = takeValue(args[i], i++);
			break;
		case '--start-file':
			startFile = takeValue(args[i], i++);
			break;
		case '--stop-file':
			stopFile = takeValue(args[i], i++);
			break;
		case '--result-file':
			resultFile = takeValue(args[i], i++);
			break;
		case '--timeout-ms':
			timeoutMs = Number(takeValue(args[i], i++));
			break;
		case '--drain-ms':
			drainMs = Number(takeValue(args[i], i++));
			break;
		case '-h':
		case '--help':
			usage();
			process.exit(0);
			break;
		default:
			fail(`unknown argument: ${args[i]}`);
	}
}

if (!readyFile || !startFile || !stopFile || !resultFile)
	fail('--ready-file, --start-file, --stop-file, and --result-file are required');
for (const [name, value] of [
	['timeout-ms', timeoutMs],
	['drain-ms', drainMs]
]) {
	if (!Number.isInteger(value) || value <= 0) fail(`${name} must be a positive integer`);
}

function writeMarker(file, value) {
	fs.mkdirSync(path.dirname(path.resolve(file)), { recursive: true });
	fs.writeFileSync(file, `${JSON.stringify(value)}\n`, { mode: 0o600 });
}

function waitForFile(file, timeoutMs) {
	const deadline = Date.now() + timeoutMs;
	return new Promise((resolve, reject) => {
		const check = () => {
			if (fs.existsSync(file)) return resolve();
			if (Date.now() >= deadline) return reject(new Error(`timed out waiting for ${file}`));
			setTimeout(check, 50);
		};
		check();
	});
}

function percentile(values, p) {
	if (!values.length) return null;
	const sorted = values.slice().sort((a, b) => a - b);
	const index = Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p));
	return Number(sorted[index].toFixed(2));
}

function intervalsSummary(times) {
	const intervals = [];
	for (let i = 1; i < times.length; i++) intervals.push(times[i] - times[i - 1]);
	return {
		count: times.length,
		interval_count: intervals.length,
		p50_ms: percentile(intervals, 0.5),
		p95_ms: percentile(intervals, 0.95),
		max_ms: intervals.length ? Number(Math.max(...intervals).toFixed(2)) : null
	};
}

function requestMethods(postData) {
	const methods = ['poll', 'rules', 'resolve', 'logging_status'];
	return methods.filter((method) => fwliveMethodRequestIds(postData, method).length > 0);
}

function hasSummary(value) {
	if (Array.isArray(value)) return value.some(hasSummary);
	if (!value || typeof value !== 'object') return false;
	if (Object.prototype.hasOwnProperty.call(value, 'summary')) return true;
	return Object.values(value).some(hasSummary);
}

async function main() {
	const { launchLabBrowser, loginFwlive } = await import('./lib/playwright-lab.mjs');
	const { browser, page } = await launchLabBrowser();
	const requestTimes = [];
	const methodCounts = {};
	const measuredRequests = new Set();
	const measuredInFlight = new Set();
	const ignoredFailures = new Set();
	const pollRequests = new Set();
	let measureStarted = false;
	let measureFinished = false;
	let summarySeen = false;
	let requestFailures = 0;
	let firstPollSettled = false;
	let firstPollResponseResolve;
	let firstPollResponseReject;
	const firstPollResponsePromise = new Promise((resolve, reject) => {
		firstPollResponseResolve = resolve;
		firstPollResponseReject = reject;
	});

	page.on('request', (request) => {
		const postData = request.postData() || '';
		const methods = requestMethods(postData);
		if (!methods.length) return;
		for (const method of methods) methodCounts[method] = (methodCounts[method] || 0) + 1;
		if (methods.includes('poll')) pollRequests.add(request);
		if (measureStarted && !measureFinished) {
			measuredRequests.add(request);
			measuredInFlight.add(request);
			for (const method of methods)
				methodCounts[`window_${method}`] = (methodCounts[`window_${method}`] || 0) + 1;
			if (methods.includes('poll')) requestTimes.push(Date.now());
		}
	});
	page.on('requestfinished', (request) => {
		measuredInFlight.delete(request);
		pollRequests.delete(request);
	});
	page.on('requestfailed', (request) => {
		const wasPoll = pollRequests.has(request);
		measuredInFlight.delete(request);
		pollRequests.delete(request);
		if (measuredRequests.has(request) && !ignoredFailures.has(request)) requestFailures++;
		if (!firstPollSettled && wasPoll) {
			firstPollSettled = true;
			firstPollResponseReject(new Error('first fwlive poll request failed'));
		}
	});
	page.on('response', async (response) => {
		const postData = response.request().postData() || '';
		const methods = requestMethods(postData);
		if (!methods.length) return;
		if (methods.includes('poll')) {
			try {
				if (!response.ok()) throw new Error(`HTTP ${response.status()}`);
				const body = await response.json();
				const pollIds = fwliveMethodRequestIds(postData, 'poll');
				const pollReply = fwliveRpcReplyForRequest(body, pollIds);
				if (!isSuccessfulFwliveRpcReply(pollReply))
					throw new Error('poll RPC reply was missing or unsuccessful');
				if (!pollReply.result[1] || typeof pollReply.result[1] !== 'object')
					throw new Error('poll RPC result payload was missing or invalid');
				if (!firstPollSettled) {
					firstPollSettled = true;
					firstPollResponseResolve();
				}
				if (measureStarted && !measureFinished && hasSummary(body)) summarySeen = true;
			} catch (error) {
				if (measuredRequests.has(response.request()) && !ignoredFailures.has(response.request())) requestFailures++;
				if (!firstPollSettled) {
					firstPollSettled = true;
					firstPollResponseReject(error);
				}
			}
		}
	});

	try {
		await loginFwlive(page);
		await Promise.race([
			firstPollResponsePromise,
			new Promise((_, reject) =>
				setTimeout(
					() => reject(new Error('timed out waiting for the first fwlive poll')),
					30000
				)
			)
		]);
		writeMarker(readyFile, { pid: process.pid, ready_at: new Date().toISOString() });
		await waitForFile(startFile, 60000);
		measureStarted = true;
		const startedAt = Date.now();
		await waitForFile(stopFile, timeoutMs);
		measureFinished = true;
		const finishedAt = Date.now();
		const requestsBeforeDrain = measuredInFlight.size;
		// Let measured requests settle before navigating away. If a request is
		// still in flight at the bounded drain deadline, navigation may cancel it;
		// exclude that teardown cancellation from the request-failure metric.
		const drainDeadline = Date.now() + drainMs;
		while (measuredInFlight.size && Date.now() < drainDeadline)
			await new Promise((resolve) => setTimeout(resolve, 25));
		const inFlightAfterDrain = measuredInFlight.size;
		for (const request of measuredInFlight) ignoredFailures.add(request);
		const navigationTimeout = Math.max(1, drainDeadline - Date.now());
		await page.goto('about:blank', { waitUntil: 'load', timeout: navigationTimeout }).catch(() => {});
		while (measuredInFlight.size && Date.now() < drainDeadline)
			await new Promise((resolve) => setTimeout(resolve, 25));
		const report = {
			viewer: 'active',
			duration_ms: finishedAt - startedAt,
			requests: Object.fromEntries(
				Object.entries(methodCounts)
					.filter(([method]) => method.startsWith('window_'))
					.map(([method, count]) => [method.slice('window_'.length), count])
			),
			polls_in_window: requestTimes.length,
			poll_cadence_ms: intervalsSummary(requestTimes),
			request_failures: requestFailures,
			in_flight_at_window_end: requestsBeforeDrain,
			in_flight_after_drain: inFlightAfterDrain,
			summary_mode_seen: summarySeen,
			started_at: new Date(startedAt).toISOString(),
			finished_at: new Date(finishedAt).toISOString()
		};
		writeMarker(resultFile, report);
		console.log(JSON.stringify(report));
	} finally {
		await browser.close();
	}
}
main().catch((error) => {
	console.error(error.message || error);
	process.exit(1);
});

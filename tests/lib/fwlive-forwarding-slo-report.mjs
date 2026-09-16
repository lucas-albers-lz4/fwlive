#!/usr/bin/env node
/*
 * Build and validate the JSON report for a paired forwarding-SLO run.
 * Keeping this logic separate makes the acceptance gates unit-testable without
 * booting QEMU or a browser.
 */
import fs from 'node:fs';
import path from 'node:path';

export const REPORT_SCHEMA = 'fwlive-forwarding-slo/v1';

export function median(values) {
	if (!values.length) return null;
	const sorted = values.slice().sort((a, b) => a - b);
	const lower = Math.floor((sorted.length - 1) / 2);
	const upper = Math.ceil((sorted.length - 1) / 2);
	return (sorted[lower] + sorted[upper]) / 2;
}

function stats(values) {
	return values.length ? {
		count: values.length,
		median: median(values),
		min: Math.min(...values),
		max: Math.max(...values),
		spread: Math.max(...values) - Math.min(...values)
	} : { count: 0, median: null, min: null, max: null, spread: null };
}

export function buildReport({
	records,
	adaptive,
	expectedPairs,
	duration,
	pingCount,
	bitrate,
	startedAt,
	generatedAt = new Date().toISOString()
}) {
	const pairs = [];
	for (let pair = 1; pair <= Number(expectedPairs); pair++) {
		const rows = records.filter((row) => row.pair === pair);
		const baseline = rows.find((row) => row.mode === 'no-viewer');
		const active = rows.find((row) => row.mode === 'active-viewer');
		if (!baseline || !active) {
			pairs.push({ pair, complete: false, rows });
			continue;
		}
		pairs.push({
			pair,
			complete: true,
			throughput_degradation_pct: (1 - active.throughput_bps / baseline.throughput_bps) * 100,
			ping_stddev_ratio: baseline.ping_rtt_stddev_ms === 0
				? null
				: active.ping_rtt_stddev_ms / baseline.ping_rtt_stddev_ms
		});
	}
	const baselines = records.filter((row) => row.mode === 'no-viewer');
	const actives = records.filter((row) => row.mode === 'active-viewer');
	const degradation = pairs.filter((row) => row.complete).map((row) => row.throughput_degradation_pct);
	const ratios = pairs.filter((row) => row.complete && row.ping_stddev_ratio !== null).map((row) => row.ping_stddev_ratio);
	const report = {
		schema: REPORT_SCHEMA,
		issue: 306,
		child_issue: 344,
		adaptive,
		configuration: {
			pairs_requested: Number(expectedPairs),
			duration_s: Number(duration),
			ping_count: Number(pingCount),
			iperf_bitrate: bitrate || 'unlimited',
			viewer_baseline: 'no-viewer',
			viewer_comparison: 'active-viewer',
			traffic: 'iperf3 receive throughput plus routed ping RTT standard deviation'
		},
		acceptance: {
			all_pairs_complete: pairs.length === Number(expectedPairs) && pairs.every((row) => row.complete),
			active_viewer_poll_observed: actives.length === Number(expectedPairs) && actives.every((row) => row.viewer.polls_in_window > 0),
			viewer_requests_drained: actives.length === Number(expectedPairs) && actives.every((row) => row.viewer.in_flight_after_drain === 0),
			viewer_requests_succeeded: actives.length === Number(expectedPairs) && actives.every((row) => row.viewer.request_failures === 0),
			median_throughput_degradation_lt_10_pct: median(degradation) !== null && median(degradation) < 10,
			median_ping_stddev_ratio_lt_2: median(ratios) !== null && median(ratios) < 2
		},
		throughput_degradation_pct: stats(degradation),
		ping_stddev_ratio: stats(ratios),
		throughput_bps: {
			no_viewer: stats(baselines.map((row) => row.throughput_bps)),
			active_viewer: stats(actives.map((row) => row.throughput_bps))
		},
		ping_rtt_stddev_ms: {
			no_viewer: stats(baselines.map((row) => row.ping_rtt_stddev_ms)),
			active_viewer: stats(actives.map((row) => row.ping_rtt_stddev_ms))
		},
		pairs,
		samples: records,
		started_at: startedAt,
		generated_at: generatedAt
	};
	report.pass = Object.values(report.acceptance).every(Boolean);
	return report;
}

export function writeReport(reportFile, report, stagingDirectory) {
	if (!reportFile) return;
	const staged = path.join(stagingDirectory, 'report.json.tmp');
	const descriptor = fs.openSync(staged, 'wx', 0o600);
	try {
		fs.writeFileSync(descriptor, `${JSON.stringify(report, null, 2)}\n`);
	} finally {
		fs.closeSync(descriptor);
	}
	fs.renameSync(staged, reportFile);
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
	const [recordsFile, reportFile, adaptive, expectedPairs, duration, pingCount, bitrate, enforce, startedAt] = process.argv.slice(2);
	const records = fs.readFileSync(recordsFile, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
	const report = buildReport({ records, adaptive, expectedPairs, duration, pingCount, bitrate, startedAt });
	writeReport(reportFile, report, path.dirname(recordsFile));
	console.log(JSON.stringify(report, null, 2));
	if (enforce === '1' && !report.pass) process.exit(1);
}

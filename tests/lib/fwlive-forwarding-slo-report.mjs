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
	const numeric = values.filter(Number.isFinite);
	return numeric.length ? {
		count: numeric.length,
		median: median(numeric),
		min: Math.min(...numeric),
		max: Math.max(...numeric),
		spread: Math.max(...numeric) - Math.min(...numeric)
	} : { count: 0, median: null, min: null, max: null, spread: null };
}

function hasCpuCoreCounters(scope) {
	const cores = scope?.cpu_per_core;
	return !!cores && typeof cores === 'object' && !Array.isArray(cores) &&
		Object.entries(cores).some(([cpu, counters]) =>
			/^cpu\d+$/.test(cpu) && Number.isFinite(counters?.total_ticks) && Number.isFinite(counters?.busy_ticks));
}

export function buildReport({
	records,
	adaptive,
	expectedPairs,
	duration,
	pingCount,
	bitrate,
	streams = 1,
	metadata = {},
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
		const trafficValid = [baseline, active].every((row) =>
			row.traffic?.status === 'valid' &&
			Number.isFinite(row.throughput_bps) && row.throughput_bps > 0 &&
			Number.isFinite(row.ping_rtt_stddev_ms) &&
			row.traffic.ping_loss_pct === 0 &&
			row.traffic.streams === Number(streams) &&
			row.traffic.requested_streams === Number(streams) &&
			row.traffic.observed_streams === Number(streams) &&
			row.traffic.stream_evidence_mismatch === false);
		pairs.push({
			pair,
			complete: true,
			traffic_valid: trafficValid,
			throughput_degradation_pct: !trafficValid ? null : (1 - active.throughput_bps / baseline.throughput_bps) * 100,
			ping_stddev_ratio: !trafficValid || baseline.ping_rtt_stddev_ms === 0
				? null
				: active.ping_rtt_stddev_ms / baseline.ping_rtt_stddev_ms
		});
	}
	const baselines = records.filter((row) => row.mode === 'no-viewer');
	const actives = records.filter((row) => row.mode === 'active-viewer');
	const degradation = pairs.filter((row) => Number.isFinite(row.throughput_degradation_pct)).map((row) => row.throughput_degradation_pct);
	const ratios = pairs.filter((row) => Number.isFinite(row.ping_stddev_ratio)).map((row) => row.ping_stddev_ratio);
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
			iperf_bitrate_semantics: 'aggregate across all TCP streams',
			iperf_streams: Number(streams),
			viewer_baseline: 'no-viewer',
			viewer_comparison: 'active-viewer',
			traffic: 'iperf3 receive throughput/retransmits plus routed ping loss and RTT standard deviation'
		},
		acceptance: {
			all_pairs_complete: pairs.length === Number(expectedPairs) && pairs.every((row) => row.complete),
			traffic_samples_valid: records.length === Number(expectedPairs) * 2 && pairs.every((row) => row.complete && row.traffic_valid),
			raw_iperf_and_ping_retained: records.length === Number(expectedPairs) * 2 && records.every((row) =>
				['iperf-client.json', 'iperf-server.json', 'ping.txt'].every((name) => typeof row.raw?.[name] === 'string')),
			telemetry_captured: records.length === Number(expectedPairs) * 2 && records.every((row) =>
				row.telemetry?.host && row.telemetry?.guest &&
				hasCpuCoreCounters(row.telemetry.host) && hasCpuCoreCounters(row.telemetry.guest)),
			active_viewer_poll_observed: actives.length === Number(expectedPairs) && actives.every((row) => row.viewer.polls_in_window > 0),
			viewer_poll_response_details_captured: actives.length === Number(expectedPairs) && actives.every((row) =>
				Array.isArray(row.viewer.poll_responses) && row.viewer.poll_responses.length > 0 &&
				row.viewer.poll_responses.every((poll) => Number.isFinite(poll.received_rows) && Number.isFinite(poll.requested_lines))),
			viewer_requests_drained: actives.length === Number(expectedPairs) && actives.every((row) => row.viewer.in_flight_after_drain === 0),
			viewer_response_parses_drained: actives.length === Number(expectedPairs) && actives.every((row) =>
				row.viewer.pending_response_parses_at_drain === 0 &&
				row.viewer.pending_response_parses_after_navigation === 0),
			viewer_requests_succeeded: actives.length === Number(expectedPairs) && actives.every((row) => row.viewer.request_failures === 0),
			median_throughput_degradation_lt_10_pct: median(degradation) !== null && median(degradation) < 10,
			median_ping_stddev_ratio_lt_2: ratios.length === Number(expectedPairs) && median(ratios) !== null && median(ratios) < 2
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
		generator_cpu_pct: {
			no_viewer: stats(baselines.map((row) => row.traffic?.generator_cpu_pct).filter(Number.isFinite)),
			active_viewer: stats(actives.map((row) => row.traffic?.generator_cpu_pct).filter(Number.isFinite))
		},
		iperf_retransmits: {
			no_viewer: stats(baselines.map((row) => row.traffic?.retransmits).filter(Number.isFinite)),
			active_viewer: stats(actives.map((row) => row.traffic?.retransmits).filter(Number.isFinite))
		},
		ping_loss_pct: {
			no_viewer: stats(baselines.map((row) => row.traffic?.ping_loss_pct).filter(Number.isFinite)),
			active_viewer: stats(actives.map((row) => row.traffic?.ping_loss_pct).filter(Number.isFinite))
		},
		metadata,
		pairs,
		samples: records,
		started_at: startedAt,
		generated_at: generatedAt
	};
	report.pass = Object.values(report.acceptance).every(Boolean);
	return report;
}

export function writeReport(reportFile, report) {
	if (!reportFile) return;
	const reportPath = path.resolve(reportFile);
	const reportDirectory = path.dirname(reportPath);
	const staged = path.join(reportDirectory, `.${path.basename(reportPath)}.${process.pid}.${Date.now()}.tmp`);
	const descriptor = fs.openSync(staged, 'wx', 0o600);
	try {
		fs.writeFileSync(descriptor, `${JSON.stringify(report, null, 2)}\n`);
	} finally {
		fs.closeSync(descriptor);
	}
	try {
		fs.renameSync(staged, reportPath);
	} catch (error) {
		fs.rmSync(staged, { force: true });
		throw error;
	}
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
	const [recordsFile, reportFile, adaptive, expectedPairs, duration, pingCount, bitrate, streams, enforce, startedAt, metadataFile] = process.argv.slice(2);
	const records = fs.readFileSync(recordsFile, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
	const metadata = metadataFile ? JSON.parse(fs.readFileSync(metadataFile, 'utf8')) : {};
	const report = buildReport({ records, adaptive, expectedPairs, duration, pingCount, bitrate, streams, metadata, startedAt });
	writeReport(reportFile, report);
	console.log(JSON.stringify(report, null, 2));
	if (enforce === '1' && !report.pass) process.exit(1);
}

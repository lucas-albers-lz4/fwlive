#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildReport, median, REPORT_SCHEMA, writeReport } from './lib/fwlive-forwarding-slo-report.mjs';

assert.equal(median([]), null);
assert.equal(median([5]), 5);
assert.equal(median([1, 4]), 2.5);
assert.equal(median([1, 3, 5, 9]), 4);

const viewer = (requestFailures = 0) => ({
	polls_in_window: 2,
	poll_responses: [{ requested_lines: 2000, received_rows: 1900, truncated: false, shed: null }],
	in_flight_after_drain: 0,
	pending_response_parses_at_drain: 0,
	pending_response_parses_after_navigation: 0,
	request_failures: requestFailures
});
const sampleEvidence = {
	traffic: {
		status: 'valid', streams: 1, requested_streams: 1, observed_streams: 1,
		connected_streams: 1, completed_streams: 1, stream_evidence_mismatch: false,
		generator_cpu_pct: 25, retransmits: 0, ping_loss_pct: 0
	},
	telemetry: {
		host: { cpu_per_core: { cpu0: { total_ticks: 10, busy_ticks: 5 } } },
		guest: { cpu_per_core: { cpu0: { total_ticks: 10, busy_ticks: 5 } } }
	},
	raw: { 'iperf-client.json': '{}', 'iperf-server.json': '{}', 'ping.txt': '0% packet loss' }
};
const records = [
	{ ...sampleEvidence, pair: 1, mode: 'no-viewer', throughput_bps: 100, ping_rtt_stddev_ms: 10, viewer: {} },
	{ ...sampleEvidence, pair: 1, mode: 'active-viewer', throughput_bps: 95, ping_rtt_stddev_ms: 15, viewer: viewer() },
	{ ...sampleEvidence, pair: 2, mode: 'no-viewer', throughput_bps: 100, ping_rtt_stddev_ms: 10, viewer: {} },
	{ ...sampleEvidence, pair: 2, mode: 'active-viewer', throughput_bps: 92, ping_rtt_stddev_ms: 12, viewer: viewer() }
];
const report = buildReport({
	records,
	adaptive: 'on',
	expectedPairs: 2,
	duration: 10,
	pingCount: 20,
	bitrate: '100M',
	startedAt: '2026-09-16T00:00:00.000Z',
	generatedAt: '2026-09-16T00:01:00.000Z'
});
assert.equal(report.schema, REPORT_SCHEMA);
assert.equal(report.throughput_degradation_pct.median, 6.5);
assert.equal(report.ping_stddev_ratio.median, 1.35);
assert.equal(report.acceptance.viewer_requests_succeeded, true);
assert.equal(report.acceptance.viewer_response_parses_drained, true);
assert.equal(report.acceptance.raw_iperf_and_ping_retained, true);
assert.equal(report.acceptance.telemetry_captured, true);
assert.equal(report.acceptance.viewer_poll_response_details_captured, true);
assert.equal(report.pass, true);
assert.equal(report.started_at, '2026-09-16T00:00:00.000Z');

const failed = buildReport({
	records: records.map((row) => row.mode === 'active-viewer'
		? { ...row, viewer: viewer(1) }
		: row),
	adaptive: 'on',
	expectedPairs: 2,
	duration: 10,
	pingCount: 20,
	bitrate: '',
	startedAt: 'now'
});
assert.equal(failed.acceptance.viewer_requests_succeeded, false);
assert.equal(failed.pass, false);

const pendingResponseParses = buildReport({
	records: records.map((row) => row.mode === 'active-viewer'
		? { ...row, viewer: { ...viewer(), pending_response_parses_at_drain: 1 } }
		: row),
	adaptive: 'on', expectedPairs: 2, duration: 10, pingCount: 20,
	bitrate: '', startedAt: 'now'
});
assert.equal(pendingResponseParses.acceptance.viewer_response_parses_drained, false);
assert.equal(pendingResponseParses.pass, false);

const missingEvidence = buildReport({
	records: records.map((row) => ({ ...row, raw: {} })),
	adaptive: 'on',
	expectedPairs: 2,
	duration: 10,
	pingCount: 20,
	bitrate: '100M',
	startedAt: 'now'
});
assert.equal(missingEvidence.acceptance.raw_iperf_and_ping_retained, false);
assert.equal(missingEvidence.pass, false);

const missingCpuCounters = buildReport({
	records: records.map((row) => ({
		...row,
		telemetry: { host: { cpu_per_core: {} }, guest: { cpu_per_core: {} } }
	})),
	adaptive: 'on',
	expectedPairs: 2,
	duration: 10,
	pingCount: 20,
	bitrate: '100M',
	startedAt: 'now'
});
assert.equal(missingCpuCounters.acceptance.telemetry_captured, false);
assert.equal(missingCpuCounters.pass, false);

const invalidTraffic = buildReport({
	records: records.map((row) => row.pair === 1 && row.mode === 'no-viewer'
		? { ...row, traffic: { ...row.traffic, status: 'invalid', reason: 'ping_packet_loss', ping_loss_pct: 5 } }
		: row),
	adaptive: 'on',
	expectedPairs: 2,
	duration: 10,
	pingCount: 20,
	bitrate: '100M',
	startedAt: 'now'
});
assert.equal(invalidTraffic.acceptance.all_pairs_complete, true);
assert.equal(invalidTraffic.acceptance.traffic_samples_valid, false);
assert.equal(invalidTraffic.pairs[0].throughput_degradation_pct, null);
assert.equal(invalidTraffic.pass, false);

const invalidStreamEvidence = buildReport({
	records: records.map((row) => row.mode === 'active-viewer'
		? { ...row, traffic: { ...row.traffic, stream_evidence_mismatch: true } }
		: row),
	adaptive: 'on',
	expectedPairs: 2,
	duration: 10,
	pingCount: 20,
	bitrate: '100M',
	startedAt: 'now'
});
assert.equal(invalidStreamEvidence.acceptance.traffic_samples_valid, false);
assert.equal(invalidStreamEvidence.pass, false);

const incomplete = buildReport({
	records: records.slice(0, 1),
	adaptive: 'off',
	expectedPairs: 1,
	duration: 10,
	pingCount: 20,
	bitrate: '',
	startedAt: 'now'
});
assert.equal(incomplete.acceptance.all_pairs_complete, false);
assert.equal(incomplete.acceptance.median_ping_stddev_ratio_lt_2, false);
assert.equal(incomplete.pass, false);

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-slo-report-test.'));
const victim = path.join(tempDir, 'victim');
const reportPath = path.join(tempDir, 'report.json');
fs.writeFileSync(victim, 'unchanged\n');
fs.symlinkSync(victim, reportPath);
writeReport(reportPath, report);
assert.equal(fs.readFileSync(victim, 'utf8'), 'unchanged\n');
assert.equal(JSON.parse(fs.readFileSync(reportPath, 'utf8')).schema, REPORT_SCHEMA);
assert.equal(fs.statSync(reportPath).mode & 0o777, 0o600);
fs.rmSync(tempDir, { recursive: true, force: true });

console.log('fwlive forwarding SLO report tests passed');

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
	in_flight_after_drain: 0,
	request_failures: requestFailures
});
const records = [
	{ pair: 1, mode: 'no-viewer', throughput_bps: 100, ping_rtt_stddev_ms: 10, viewer: {} },
	{ pair: 1, mode: 'active-viewer', throughput_bps: 95, ping_rtt_stddev_ms: 15, viewer: viewer() },
	{ pair: 2, mode: 'no-viewer', throughput_bps: 100, ping_rtt_stddev_ms: 10, viewer: {} },
	{ pair: 2, mode: 'active-viewer', throughput_bps: 92, ping_rtt_stddev_ms: 12, viewer: viewer() }
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
assert.equal(incomplete.pass, false);

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-slo-report-test.'));
const victim = path.join(tempDir, 'victim');
const reportPath = path.join(tempDir, 'report.json');
const stagingDir = path.join(tempDir, 'staging');
fs.mkdirSync(stagingDir, { mode: 0o700 });
fs.writeFileSync(victim, 'unchanged\n');
fs.symlinkSync(victim, reportPath);
writeReport(reportPath, report, stagingDir);
assert.equal(fs.readFileSync(victim, 'utf8'), 'unchanged\n');
assert.equal(JSON.parse(fs.readFileSync(reportPath, 'utf8')).schema, REPORT_SCHEMA);
assert.equal(fs.statSync(reportPath).mode & 0o777, 0o600);
fs.rmSync(tempDir, { recursive: true, force: true });

console.log('fwlive forwarding SLO report tests passed');

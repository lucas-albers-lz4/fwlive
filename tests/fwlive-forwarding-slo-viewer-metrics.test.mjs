#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
	drainPendingResponseParses,
	summarizeFwlivePoll,
	trackPendingResponseParse,
	waitForMeasurementStartOrStop
} from './lib/fwlive-forwarding-slo-viewer.mjs';

const request = [{
	id: 17,
	method: 'call',
	params: ['00000000000000000000000000000000', 'fwlive', 'poll', { addresses: ['2000'] }]
}];
const response = [{
	id: 17,
	result: [0, {
		log: [{ line: 'fwlive-slo IN=eth1' }, { line: 'fwlive-slo OUT=eth0' }],
		effective_limit: 800,
		truncated: 1,
		shed: { limit: 800, overflow: 3 },
		adaptive: 1,
		summary: { truncated: true }
	}]
}];
assert.deepEqual(summarizeFwlivePoll({
	requestPayload: JSON.stringify(request),
	responsePayload: response,
	requestOffsetMs: 500,
	responseLatencyMs: 18,
	receivedAt: '2026-10-02T00:00:00.000Z'
}), {
	request_offset_ms: 500,
	response_latency_ms: 18,
	received_at: '2026-10-02T00:00:00.000Z',
	requested_lines: 2000,
	received_rows: 2,
	effective_limit: 800,
	truncated: true,
	shed: { limit: 800, overflow: 3 },
	adaptive: true,
	summary_payload_present: true
});

assert.throws(() => summarizeFwlivePoll({ requestPayload: request, responsePayload: [] }), /missing or unsuccessful/);
assert.throws(() => summarizeFwlivePoll({
	requestPayload: request,
	responsePayload: [{ id: 17, result: [0, { log: [], error: 'filter_failed' }] }]
}), /poll application error: filter_failed/);

const pending = new Set();
const pendingRequests = new Set();
const inFlight = new Set([{ id: 1 }]);
const requestObject = [...inFlight][0];
pendingRequests.add(requestObject);
let resolveBody;
const delayedBody = new Promise((resolve) => { resolveBody = resolve; });
const parsedBodies = [];
trackPendingResponseParse(
	pending,
	delayedBody.then((body) => { parsedBodies.push(body); }),
	() => pendingRequests.delete(requestObject)
);
inFlight.delete(requestObject); // requestfinished can fire before response.json() completes.
assert.equal(inFlight.size, 0);
assert.equal(pending.size, 1);
let drainResolved = false;
const drain = drainPendingResponseParses(pending, Date.now() + 500, 5).then((left) => {
	drainResolved = true;
	return left;
});
await new Promise((resolve) => setTimeout(resolve, 20));
assert.equal(drainResolved, false, 'drain must wait for a delayed response body parse');
resolveBody({ log: ['row'] });
assert.equal(await drain, 0);
assert.deepEqual(parsedBodies, [{ log: ['row'] }]);
assert.equal(pendingRequests.size, 0);

const markerDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-slo-viewer-markers.'));
const startFile = path.join(markerDir, 'start');
const stopFile = path.join(markerDir, 'stop');
fs.writeFileSync(stopFile, 'stop\n');
assert.equal(await waitForMeasurementStartOrStop(startFile, stopFile, 500), 'stopped');
fs.rmSync(markerDir, { recursive: true, force: true });
console.log('fwlive forwarding SLO viewer metrics tests passed');

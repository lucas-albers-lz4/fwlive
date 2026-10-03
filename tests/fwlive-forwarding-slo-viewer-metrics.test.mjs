#!/usr/bin/env node
import assert from 'node:assert/strict';
import { summarizeFwlivePoll } from './lib/fwlive-forwarding-slo-viewer.mjs';

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
		truncated: true,
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
console.log('fwlive forwarding SLO viewer metrics tests passed');

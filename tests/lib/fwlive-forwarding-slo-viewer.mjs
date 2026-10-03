/* SPDX-License-Identifier: GPL-2.0-only */
import fs from 'node:fs';
import {
	fwliveMethodRequestIds,
	fwlivePollRequestedLines,
	fwliveRpcReplyForRequest,
	isSuccessfulFwliveRpcReply
} from './fwlive-perf-rpc.mjs';

export function trackPendingResponseParse(pending, promise, onSettled = () => {}) {
	const tracked = Promise.resolve(promise);
	pending.add(tracked);
	tracked.then(
		() => { pending.delete(tracked); onSettled(); },
		() => { pending.delete(tracked); onSettled(); }
	);
	return tracked;
}

export async function drainPendingResponseParses(pending, deadline, intervalMs = 25) {
	while (pending.size && Date.now() < deadline)
		await new Promise((resolve) => setTimeout(resolve, intervalMs));
	return pending.size;
}

export function waitForMeasurementStartOrStop(startFile, stopFile, timeoutMs, intervalMs = 50) {
	const deadline = Date.now() + timeoutMs;
	return new Promise((resolve, reject) => {
		const check = () => {
			if (fs.existsSync(stopFile)) return resolve('stopped');
			if (fs.existsSync(startFile)) return resolve('started');
			if (Date.now() >= deadline) return reject(new Error(`timed out waiting for ${startFile} or ${stopFile}`));
			setTimeout(check, intervalMs);
		};
		check();
	});
}

export function summarizeFwlivePoll({ requestPayload, responsePayload, requestOffsetMs, responseLatencyMs, receivedAt }) {
	const pollIds = fwliveMethodRequestIds(requestPayload, 'poll');
	const pollReply = fwliveRpcReplyForRequest(responsePayload, pollIds);
	if (!isSuccessfulFwliveRpcReply(pollReply))
		throw new Error('poll RPC reply was missing or unsuccessful');
	const data = pollReply.result[1];
	if (!data || typeof data !== 'object' || Array.isArray(data))
		throw new Error('poll RPC result payload was missing or invalid');
	if (data.error !== undefined && data.error !== null && data.error !== false && data.error !== '')
		throw new Error(`poll application error: ${String(data.error)}`);
	const requestedLines = fwlivePollRequestedLines(requestPayload)[0];
	return {
		request_offset_ms: Number.isFinite(requestOffsetMs) ? requestOffsetMs : null,
		response_latency_ms: Number.isFinite(responseLatencyMs) ? responseLatencyMs : null,
		received_at: receivedAt || null,
		requested_lines: requestedLines === undefined || !Number.isFinite(Number(requestedLines))
			? null
			: Number(requestedLines),
		received_rows: Array.isArray(data.log) ? data.log.length : null,
		effective_limit: Number.isInteger(data.effective_limit) ? data.effective_limit : null,
		truncated: data.truncated === true || data.truncated === 1,
		shed: data.shed && typeof data.shed === 'object' && !Array.isArray(data.shed)
			? data.shed
			: null,
		adaptive: data.adaptive === true || data.adaptive === 1,
		summary_payload_present: !!(data.summary && typeof data.summary === 'object')
	};
}

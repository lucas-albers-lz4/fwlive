/* SPDX-License-Identifier: GPL-2.0-only */
import {
	fwliveMethodRequestIds,
	fwlivePollRequestedLines,
	fwliveRpcReplyForRequest,
	isSuccessfulFwliveRpcReply
} from './fwlive-perf-rpc.mjs';

export function summarizeFwlivePoll({ requestPayload, responsePayload, requestOffsetMs, responseLatencyMs, receivedAt }) {
	const pollIds = fwliveMethodRequestIds(requestPayload, 'poll');
	const pollReply = fwliveRpcReplyForRequest(responsePayload, pollIds);
	if (!isSuccessfulFwliveRpcReply(pollReply))
		throw new Error('poll RPC reply was missing or unsuccessful');
	const data = pollReply.result[1];
	if (!data || typeof data !== 'object' || Array.isArray(data))
		throw new Error('poll RPC result payload was missing or invalid');
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
		truncated: data.truncated === true,
		shed: data.shed && typeof data.shed === 'object' && !Array.isArray(data.shed)
			? data.shed
			: null,
		adaptive: data.adaptive === true || data.adaptive === 1,
		summary_payload_present: !!(data.summary && typeof data.summary === 'object')
	};
}

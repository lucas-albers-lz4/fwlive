/* SPDX-License-Identifier: GPL-2.0-only */

function parseRpcPayload(payload) {
	if (!payload) return [];
	let parsed = payload;
	try {
		if (typeof payload === 'string') parsed = JSON.parse(payload);
	} catch (e) {
		return [];
	}
	return Array.isArray(parsed) ? parsed : [parsed];
}

export function fwliveMethodRequestIds(payload, method) {
	return parseRpcPayload(payload)
		.filter((req) => {
			const params = req && req.params;
			return !!(
				req &&
				typeof req === 'object' &&
				req.method === 'call' &&
				Array.isArray(params) &&
				params[1] === 'fwlive' &&
				params[2] === method &&
				typeof req.id !== 'undefined'
			);
		})
		.map((req) => req.id);
}

export function isFwliveFixtureRequest(payload) {
	return (
		fwliveMethodRequestIds(payload, 'poll').length > 0 ||
		fwliveMethodRequestIds(payload, 'logging_status').length > 0
	);
}

export function fwlivePollRequestedLines(payload) {
	return parseRpcPayload(payload)
		.filter((req) => {
			const params = req && req.params;
			return !!(
				req &&
				typeof req === 'object' &&
				req.method === 'call' &&
				Array.isArray(params) &&
				params[1] === 'fwlive' &&
				params[2] === 'poll'
			);
		})
		.flatMap((req) => {
			const params = req.params;
			const args = params[3];
			return args && Array.isArray(args.addresses) && args.addresses.length
				? [String(args.addresses[0])]
				: [];
		});
}

export function fwliveRpcReplyForRequest(payload, requestIds) {
	if (!Array.isArray(requestIds) || !requestIds.length) return null;
	return parseRpcPayload(payload).find(
		(reply) => reply && requestIds.some((id) => String(id) === String(reply.id))
	) || null;
}

export function isSuccessfulFwliveRpcReply(reply) {
	return !!reply && Array.isArray(reply.result) && reply.result[0] === 0;
}

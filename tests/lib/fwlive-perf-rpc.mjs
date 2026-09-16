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

export function fwliveRpcReplyForRequest(payload, requestIds) {
	if (!Array.isArray(requestIds) || !requestIds.length) return null;
	return parseRpcPayload(payload).find(
		(reply) => reply && requestIds.some((id) => id === reply.id)
	) || null;
}

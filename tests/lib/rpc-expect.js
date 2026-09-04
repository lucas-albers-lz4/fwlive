'use strict';

/**
 * LuCI rpc.declare expect unwrap for Node harness tests.
 * Coerces wrong-type values to the expect default (LuCI parity).
 */

function typeTag(v) {
	return Object.prototype.toString.call(v);
}

function applyExpect(reply, expect) {
	if (!expect || typeof expect !== 'object')
		return reply;
	const keys = Object.keys(expect);
	if (keys.length !== 1)
		return reply;

	const k = keys[0];
	const def = expect[k];

	if (k === '') {
		if (reply != null && typeTag(reply) === typeTag(def))
			return reply;
		return def;
	}

	let val;
	if (reply != null && typeof reply === 'object' && Object.prototype.hasOwnProperty.call(reply, k))
		val = reply[k];
	else
		val = def;

	if (typeTag(val) !== typeTag(def))
		val = def;

	return val;
}

module.exports = {
	applyExpect: applyExpect,
	typeTag: typeTag
};

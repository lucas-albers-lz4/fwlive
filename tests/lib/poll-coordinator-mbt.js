'use strict';

const assert = require('node:assert/strict');
const { loadFwliveModule } = require('./load-fwlive-module');

// Only the ITF types emitted by this pinned model are accepted. Never silently
// coerce an unfamiliar trace shape into an expected state.
function decode(value) {
	if (value === null || typeof value !== 'object') return value;
	if (Array.isArray(value)) return value.map(decode);
	if ('#bigint' in value) {
		assert.match(value['#bigint'], /^-?(0|[1-9][0-9]*)$/, 'malformed ITF integer');
		const n = Number(value['#bigint']);
		assert.ok(Number.isSafeInteger(n), 'ITF integer outside safe domain');
		return n;
	}
	if ('#set' in value) return new Set(value['#set'].map(decode));
	if ('#tup' in value) return value['#tup'].map(decode);
	return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, decode(v)]));
}

// Based on createLuciPoll() in fwlive-poll-coordinator.test.js: idle add runs
// synchronously, entries dedupe by function, and last remove stops the loop.
// Explicit periodic timer ticks are excluded from this pilot's event alphabet.
function createLuciPoll(observePromise) {
	const p = {
		queue: [], active: false,
		add(fn, interval) {
			if (p.queue.some(e => e.fn === fn)) return false;
			const entry = { fn, interval };
			p.queue.push(entry);
			if (!p.active) {
				p.active = true;
				observePromise(fn());
			}
			return true;
		},
		remove(fn) {
			p.queue = p.queue.filter(e => e.fn !== fn);
			if (!p.queue.length) p.active = false;
		}
	};
	return p;
}

function driver(module = loadFwliveModule('poll-coordinator')) {
	let hidden = false;
	let visible = 0;
	const handlers = new Set();
	const runs = [];
	const observed = new Map();
	const bindings = new Map();
	const internalPromises = [];
	function observe(promise) {
		if (!observed.has(promise)) {
			const state = { settled: false };
			observed.set(promise, state);
			promise.then(() => { state.settled = true; }, () => {
				throw new Error('coordinator returned a rejected caller promise');
			});
		}
		return promise;
	}
	const poll = createLuciPoll(p => internalPromises.push(observe(p)));
	const c = module.create({
		poll,
		visibility: { add: fn => handlers.add(fn), remove: fn => handlers.delete(fn) },
		isHidden: () => hidden,
		onVisible: () => { visible++; },
		initialCadence: 1,
		run(epoch) {
			let resolve, reject;
			const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
			runs.push({ epoch, resolve, reject, completed: false });
			return promise;
		}
	});
	function bind(id, promise) {
		if (bindings.has(id)) assert.equal(promise, bindings.get(id), 'batch promise identity');
		else {
			assert.ok(![...bindings.values()].includes(promise), 'distinct batches share a promise');
			bindings.set(id, promise);
		}
	}
	async function step(state, previous) {
		const op = state.event;
		let returned;
		const beforeInternal = internalPromises.length;
		if (op === 'request') returned = observe(c.requestPoll());
		else if (op === 'catchUp') returned = observe(c.catchUp());
		else if (op === 'start') c.startPolling();
		else if (op === 'cadence') c.setCadence(state.argument);
		else if (op === 'dispose') c.dispose();
		else if (op === 'hide' || op === 'show') {
			hidden = op === 'hide';
			[...handlers].forEach(fn => fn());
		} else if (op === 'resolve' || op === 'reject') {
			const run = runs.find(r => !r.completed);
			if (run) { run.completed = true; run[op](); }
		} else assert.equal(op, 'init', 'unknown model event');

		// One complete microtask checkpoint, including runner finish and all
		// caller continuations. No real wall clock or arbitrary retry loop.
		await new Promise(resolve => setImmediate(resolve));
		const expected = state.s;
		if (internalPromises.length > beforeInternal) {
			assert.equal(internalPromises.length, beforeInternal + 1);
			// New idle registration invokes request synchronously. It joins an
			// existing pending batch or allocates the next one, independently of
			// the model's chosen next action/result.
			const id = previous ? (previous.s.pending || previous.s.nextId) : 1;
			bind(id, internalPromises[beforeInternal]);
		}
		if (expected.returned > 0) bind(expected.returned, returned);
		if (expected.returned === -1) assert.ok(observed.get(returned).settled, 'suppressed caller settled');
		assert.deepEqual(c.getState(), {
			epoch: expected.epoch, cadenceSec: expected.cadence,
			inFlight: expected.active !== 0, queued: expected.pending !== 0,
			disposed: expected.disposed
		});
		assert.equal(runs.length, expected.starts, 'runner start count');
		if (expected.active !== 0) assert.equal(runs.at(-1).epoch, expected.activeEpoch, 'runner epoch');
		assert.equal(hidden, expected.hidden);
		assert.equal(poll.queue.length, Number(expected.registered), 'poll registration count');
		assert.equal(poll.active, expected.registered, 'idle-loop registration');
		if (poll.queue.length) assert.equal(poll.queue[0].interval, expected.cadence);
		assert.equal(handlers.size, Number(expected.started && !expected.disposed), 'visibility listener lifecycle');
		assert.equal(visible, expected.visible, 'visible notification count');
		for (const [id, p] of bindings) {
			assert.equal(observed.get(p).settled, expected.settled.has(id), `batch ${id} settlement`);
		}
	}
	return { step, dispose: () => c.dispose() };
}

async function replay(raw, module) {
	assert.equal(raw['#meta']?.format, 'ITF');
	assert.equal(raw['#meta']?.status, 'ok');
	assert.ok(Array.isArray(raw.states) && raw.states.length > 1, 'empty/short trace');
	const d = driver(module);
	const states = raw.states.map(decode);
	try {
		for (let i = 0; i < states.length; i++) {
			try {
				assert.equal(states[i].count, i, 'trace count continuity');
				if (i === 0) assert.equal(states[i].event, 'init');
				else {
					assert.notEqual(states[i].event, 'init', 'unexpected reinitialization');
					assert.equal(typeof states[i]['mbt::actionTaken'], 'string');
					assert.ok(states[i]['mbt::actionTaken'].length > 0);
					const picks = states[i]['mbt::nondetPicks'];
					assert.equal(picks.command.tag, 'Some');
					assert.equal(picks.command.value, states[i].event);
					assert.equal(picks.cadence.value, states[i].argument);
				}
				await d.step(states[i], states[i - 1]);
			} catch (error) {
				error.message = `event ${i} (${states[i].event}): ${error.message}`;
				throw error;
			}
		}
	} finally { d.dispose(); }
	return states.length - 1;
}

module.exports = { decode, driver, replay };

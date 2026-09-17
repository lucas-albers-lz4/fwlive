#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { loadFwliveModule } = require('./lib/load-fwlive-module');

const policy = loadFwliveModule('render-policy');
const renderScheduler = loadFwliveModule('render-scheduler');
const rows = (ids) => ids.map((id) => ({ id }));

function makeScheduler(overrides) {
	return renderScheduler.create({
		renderCost: policy.renderCost,
		capacity: 3,
		getEpoch: () => 0,
		render: () => {},
		now: () => 0,
		...overrides
	});
}

function makeFrames() {
	const frames = [];
	const renders = [];
	const cancelled = [];
	let epoch = 0;
	let nextId = 0;
	const scheduler = makeScheduler({
		getEpoch: () => epoch,
		requestFrame: (fn) => {
			frames.push(fn);
			return nextId++;
		},
		cancelFrame: (id) => cancelled.push(id),
		render: (force) => renders.push(force)
	});
	return {
		scheduler,
		frames,
		renders,
		cancelled,
		advanceEpoch: () => epoch++,
		flush: () => {
			assert.ok(frames.length, 'expected a pending frame');
			frames.shift()();
		}
	};
}

/* The policy consumes the last painted identity, not merely an allowed paint. */
{
	const s = makeScheduler();
	assert.equal(s.shouldRender(rows(['a']), false, 99), true, 'count changes cost one');
	assert.equal(s.shouldRender(rows(['a']), false, 99), true, 'decision does not commit identity');
	s.markRendered(rows(['a']));
	assert.equal(s.shouldRender(rows(['a']), false, 99), false, 'unchanged rows skip painting');
	assert.equal(s.shouldRender(rows(['b']), false, 2), false, 'new IDs charge the batch cost');
	assert.equal(s.isFloodSuppressed(), true);
	assert.equal(s.shouldRender(rows(['b']), true, 99), true, 'forced paint bypasses the bucket');
	assert.equal(s.isFloodSuppressed(), true, 'forced paint preserves the warning');
	assert.equal(s.shouldRender(rows(['a']), false, 99), false);
	assert.equal(s.isFloodSuppressed(), false, 'unchanged rows clear the warning');
	assert.equal(s.shouldRender(rows([]), false, 99), true, 'clearing the table costs one');
	s.markRendered([]);
	assert.equal(s.shouldRender([], false, 99), false, 'empty table remains unchanged');
}

/* Recovery uses elapsed time, including clocks whose first timestamp is zero. */
{
	let time = 0;
	const s = makeScheduler({ now: () => time });
	s.markRendered(rows(['a']));
	assert.equal(s.shouldRender(rows(['b']), false, 3), true);
	s.markRendered(rows(['b']));
	assert.equal(s.shouldRender(rows(['c']), false, 1), false);
	time = 500;
	assert.equal(s.shouldRender(rows(['c']), false, 1), true, 'half a second refills 1.5 tokens');
	s.markRendered(rows(['c']));
	assert.equal(s.isFloodSuppressed(), false, 'budget recovery clears the warning');
	time = 400;
	assert.equal(s.shouldRender(rows(['d']), false, 1), false, 'clock rollback grants no tokens');
	time = 600;
	assert.equal(
		s.shouldRender(rows(['d']), false, 1),
		true,
		'clock rollback creates no token debt'
	);
	time = 10000;
	assert.equal(s.shouldRender(rows(['e']), false, 4), false, 'refill never exceeds capacity');
	s.resetBudget();
	assert.equal(s.isFloodSuppressed(), false);
	assert.equal(s.shouldRender(rows(['e']), false, 3), true, 'reset restores capacity');
	assert.equal(s.shouldRender(rows(['f']), true, 3), true);
	assert.equal(s.shouldRender(rows(['f']), false, 1), false, 'forced paint does not refill');
	time = 10500;
	s.resetBudget();
	assert.equal(s.shouldRender(rows(['g']), true, 99), true);
	time = 11000;
	assert.equal(s.shouldRender(rows(['g']), false, 3), true);
	assert.equal(s.shouldRender(rows(['h']), false, 1), false, 'reset does not bank elapsed time');
}

{
	const h = makeFrames();
	h.scheduler.schedule(false);
	h.scheduler.schedule(true);
	h.scheduler.schedule(false);
	assert.equal(h.frames.length, 1, 'requests coalesce even when frame ID is zero');
	h.flush();
	assert.deepEqual(h.renders, [true], 'same-epoch force wins');
	h.scheduler.schedule(false);
	h.flush();
	assert.deepEqual(h.renders, [true, false], 'force expires after painting');
}

/* Refresh cleanup cancels only its own unused reservation. */
{
	const h = makeFrames();
	const cancelFirst = h.scheduler.forceNextRender();
	h.scheduler.schedule(false);
	cancelFirst();
	h.flush();
	assert.deepEqual(h.renders, [true], 'cleanup cannot erase force already queued');
	const cancelSecond = h.scheduler.forceNextRender();
	cancelFirst();
	h.scheduler.schedule(false);
	h.flush();
	assert.deepEqual(h.renders, [true, true], 'old cleanup cannot cancel a newer reservation');
	cancelSecond();
	const cancelThird = h.scheduler.forceNextRender();
	cancelThird();
	h.scheduler.schedule(false);
	h.flush();
	assert.deepEqual(h.renders, [true, true, false], 'unused reservation expires on cancellation');
}

/* Only the latest epoch may paint; coalesced display changes still force it. */
for (const force of [false, true]) {
	const h = makeFrames();
	h.scheduler.schedule(true);
	h.advanceEpoch();
	h.flush();
	assert.deepEqual(h.renders, [], 'stale frame without a new request is discarded');
	assert.equal(h.frames.length, 0, 'discard does not invent work');

	h.scheduler.schedule(force);
	h.advanceEpoch();
	h.scheduler.schedule(false);
	h.flush();
	assert.deepEqual(h.renders, [], 'stale callback must not paint');
	assert.equal(h.frames.length, 1, 'latest request gets a fresh frame');
	h.flush();
	assert.deepEqual(
		h.renders,
		[force],
		'requeue retains force for display changes with unchanged row IDs'
	);
}

{
	const h = makeFrames();
	h.scheduler.schedule(false);
	h.advanceEpoch();
	h.scheduler.schedule(true);
	h.advanceEpoch();
	h.flush();
	assert.deepEqual(h.renders, [], 'queued request can itself become stale');
	assert.equal(h.frames.length, 0);
	h.scheduler.schedule(false);
	h.flush();
	assert.deepEqual(h.renders, [false], 'later work is not forced by discarded intent');
}

{
	const h = makeFrames();
	h.scheduler.schedule(true);
	h.scheduler.dispose();
	h.scheduler.dispose();
	assert.deepEqual(h.cancelled, [0], 'dispose cancels frame zero exactly once');
	h.flush(); // Simulate delivery even if cancellation was too late.
	h.scheduler.schedule(true);
	assert.deepEqual(h.renders, [], 'disposal is terminal');
	assert.equal(h.frames.length, 0);
	assert.equal(
		h.scheduler.shouldRender(rows(['a']), true, 1),
		false,
		'disposed view cannot paint'
	);
}

{
	const renders = [];
	const s = makeScheduler({ render: (force) => renders.push(force) });
	s.schedule(false);
	s.schedule(true);
	assert.deepEqual(renders, [false, true], 'no frame API uses synchronous fallback');
	s.dispose();
	s.schedule(true);
	assert.deepEqual(renders, [false, true], 'fallback also respects disposal');
}

console.log('fwlive render-scheduler tests passed');

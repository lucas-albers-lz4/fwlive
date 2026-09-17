'use strict';
/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2025-2026 Lucas Albers <lucas.b.albers@gmail.com> */

'require baseclass';

function settle(waiters, value) {
	for (let i = 0; i < waiters.length; i++) waiters[i].resolve(value);
}

function createCoordinator(options) {
	options = options || {};

	const poll = options.poll || {};
	const visibility = options.visibility || {};
	const isHidden =
		options.isHidden ||
		function () {
			return false;
		};
	const runRequest =
		options.run ||
		function () {
			return Promise.resolve();
		};
	const state = {
		epoch: 0,
		cadenceSec: options.initialCadence || 1,
		inFlight: false,
		disposed: false,
		queued: false
	};
	let pollFn = null;
	let currentRun = null;
	let activeWaiters = [];
	let queuedWaiters = [];
	let visibilityHandler = null;

	function publish() {
		if (typeof options.onStateChange !== 'function') return;
		options.onStateChange({
			epoch: state.epoch,
			cadenceSec: state.cadenceSec,
			inFlight: state.inFlight,
			disposed: state.disposed,
			queued: state.queued,
			pollFn: pollFn,
			promise: currentRun,
			waiters: activeWaiters.slice(),
			queuedWaiters: queuedWaiters.slice()
		});
	}

	function bumpEpoch() {
		state.epoch++;
		if (typeof options.onEpochChange === 'function') options.onEpochChange(state.epoch);
	}

	function removePoll() {
		if (!pollFn || typeof poll.remove !== 'function') return;
		try {
			poll.remove(pollFn);
		} catch (e) {
			/* poll gone */
		}
	}

	function addPoll() {
		if (!pollFn || typeof poll.add !== 'function' || isHidden()) return;
		try {
			poll.add(pollFn, state.cadenceSec);
		} catch (e) {
			/* poll gone */
		}
	}

	function finish(run, value) {
		if (currentRun !== run) return;

		const waiters = activeWaiters;
		activeWaiters = [];
		currentRun = null;
		state.inFlight = false;
		publish();
		settle(waiters, value);

		if (state.queued && !state.disposed && !isHidden()) {
			const queued = queuedWaiters;
			queuedWaiters = [];
			state.queued = false;
			start(queued);
		}
	}

	function start(waiters) {
		const epoch = state.epoch;
		state.inFlight = true;
		let run;
		try {
			run = Promise.resolve(runRequest(epoch));
		} catch (e) {
			run = Promise.reject(e);
		}
		currentRun = run;
		activeWaiters = waiters;
		publish();
		run.then(
			function (value) {
				finish(run, value);
			},
			function () {
				finish(run);
			}
		);
	}

	function requestPoll() {
		if (state.disposed || isHidden()) return Promise.resolve();

		const waiter = {};
		const promise = new Promise(function (resolve) {
			waiter.resolve = resolve;
		});

		if (currentRun) {
			state.queued = true;
			queuedWaiters.push(waiter);
			publish();
			return promise;
		}

		if (state.queued) {
			queuedWaiters.push(waiter);
			const queued = queuedWaiters;
			queuedWaiters = [];
			state.queued = false;
			start(queued);
			return promise;
		}

		start([waiter]);
		return promise;
	}

	function setCadence(sec) {
		state.cadenceSec = sec > 0 ? sec : 1;
		if (!pollFn || isHidden()) {
			publish();
			return;
		}
		removePoll();
		addPoll();
		publish();
	}

	function stopPolling() {
		removePoll();
		publish();
	}

	function bumpEpochForOwner() {
		bumpEpoch();
		publish();
		return state.epoch;
	}

	function onVisibilityChange() {
		if (isHidden()) {
			removePoll();
			bumpEpoch();
			publish();
			return;
		}
		if (state.disposed) return;

		bumpEpoch();
		if (typeof options.onVisible === 'function') options.onVisible();
		setCadence(state.cadenceSec);
		requestPoll();
	}

	function bind() {
		if (visibilityHandler || typeof visibility.add !== 'function') return;
		visibilityHandler = onVisibilityChange;
		visibility.add(visibilityHandler);
	}

	function unbind() {
		if (!visibilityHandler || typeof visibility.remove !== 'function') return;
		try {
			visibility.remove(visibilityHandler);
		} catch (e) {
			/* document gone */
		}
		visibilityHandler = null;
	}

	function startPolling() {
		if (state.disposed) return;
		if (!pollFn) {
			pollFn = requestPoll;
			if (typeof options.onPollFunction === 'function') options.onPollFunction(pollFn);
		}
		addPoll();
		publish();
	}

	function adoptPollFunction(fn) {
		if (pollFn || typeof fn !== 'function') return;
		pollFn = fn;
		publish();
	}

	function dispose() {
		if (state.disposed) return;
		state.disposed = true;
		bumpEpoch();
		removePoll();
		unbind();
		pollFn = null;

		const active = activeWaiters;
		activeWaiters = [];
		currentRun = null;
		state.inFlight = false;
		state.queued = false;
		const queued = queuedWaiters;
		queuedWaiters = [];
		publish();
		settle(active);
		settle(queued);
	}

	return {
		bind: bind,
		dispose: dispose,
		getState: function () {
			return {
				epoch: state.epoch,
				cadenceSec: state.cadenceSec,
				inFlight: state.inFlight,
				disposed: state.disposed,
				queued: state.queued,
				pollFn: pollFn
			};
		},
		onVisibilityChange: onVisibilityChange,
		adoptPollFunction: adoptPollFunction,
		bumpEpoch: bumpEpochForOwner,
		setCadence: setCadence,
		stopPolling: stopPolling,
		startPolling: startPolling,
		unbind: unbind,
		requestPoll: requestPoll
	};
}

return baseclass.extend({
	create: createCoordinator
});

'use strict';

const childProcess = require('node:child_process');

const DEFAULT_TIMEOUT_MS = 30_000;

function withChildProcessTimeout(options) {
	const timed = Object.assign({}, options || {});
	if (!Number.isFinite(timed.timeout) || timed.timeout <= 0)
		timed.timeout = DEFAULT_TIMEOUT_MS;
	else
		timed.timeout = Math.min(timed.timeout, DEFAULT_TIMEOUT_MS);
	if (!timed.killSignal)
		timed.killSignal = 'SIGKILL';
	// These helpers pass executable and argv separately; never enable shell parsing.
	timed.shell = false;
	return timed;
}

function execFileSync(file, args, options) {
	return childProcess.execFileSync(file, args, withChildProcessTimeout(options));
}

function spawnSync(file, args, options) {
	return childProcess.spawnSync(file, args, withChildProcessTimeout(options));
}

function spawn(file, args, options) {
	return childProcess.spawn(file, args, withChildProcessTimeout(options));
}

module.exports = {
	DEFAULT_TIMEOUT_MS,
	execFileSync,
	spawnSync,
	spawn,
	withChildProcessTimeout
};

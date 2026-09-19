'use strict';

/**
 * Load view/status/fwlive.js under Node with stubbed rpc/poll/view and real fwlive modules.
 */

const fs = require('fs');
const path = require('path');
const { loadFwliveModule, fakeGettext } = require('./load-fwlive-module');
const { applyExpect } = require('./rpc-expect');
const luciE = require('./luci-e-harness');

const ROOT = path.join(__dirname, '..', '..');
const VIEW_PATH = path.join(
	ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js'
);

class HarnessElement extends luciE.Element {
	constructor(tagName) {
		super(tagName);
		this.className = '';
		this.textContent = '';
		this.style = { display: '' };
	}

	setAttribute(key, value) {
		super.setAttribute(key, value);
		if (key === 'id')
			this._id = String(value);
	}
}

function createHarnessDocument() {
	const idMap = Object.create(null);

	const document = {
		hidden: false,
		_visListeners: [],
		createElement(tagName) {
			const el = new HarnessElement(tagName);
			el.setAttribute = function(key, value) {
				HarnessElement.prototype.setAttribute.call(this, key, value);
				if (key === 'id')
					idMap[value] = this;
			}.bind(el);
			return el;
		},
		createTextNode(text) {
			return new luciE.TextNode(text);
		},
		createDocumentFragment() {
			return new luciE.DocumentFragment();
		},
		getElementById(id) {
			return idMap[id] || null;
		},
		addEventListener(type, fn) {
			if (type === 'visibilitychange')
				this._visListeners.push(fn);
		},
		dispatchVisibility() {
			for (let i = 0; i < this._visListeners.length; i++)
				this._visListeners[i]();
		},
		body: {
			appendChild(node) {
				indexElementIds(node, idMap);
			}
		}
	};

	return { document: document, idMap: idMap };
}

function indexElementIds(node, idMap) {
	if (!node)
		return;
	if (node._attrs && node._attrs.id)
		idMap[node._attrs.id] = node;
	if (node._id)
		idMap[node._id] = node;
	for (let i = 0; i < (node.childNodes || []).length; i++)
		indexElementIds(node.childNodes[i], idMap);
}

function defaultRpcReply(key) {
	switch (key) {
	case 'fwlive.rules':
		return { rules: {} };
	case 'fwlive.resolve':
		return { names: {} };
	case 'fwlive.logging_status':
		return {
			wan_zone: null,
			wan_zone_candidates: [],
			wan_log: false,
			wan_log_limit: null,
			nf_log_ipv4: false,
			nf_log_ipv6: false,
			ready: false,
			weak_device: false,
			blockers: [],
			warnings: []
		};
	case 'fwlive.poll':
		return { log: [] };
	default:
		return {};
	}
}

function loadFwliveView(options) {
	options = options || {};
	const rpcMocks = Object.assign(Object.create(null), options.rpcMocks || {});
	const rawRpcKeys = options.rawRpcKeys || Object.create(null);
	const storage = Object.assign(Object.create(null), options.storage || {});
	const location = options.location || { hash: '' };

	const harness = options.document
		? { document: options.document, idMap: Object.create(null) }
		: createHarnessDocument();
	const document = harness.document;
	const localStorage = {
		getItem: function (k) {
			return Object.prototype.hasOwnProperty.call(storage, k) ? storage[k] : null;
		},
		setItem: function (k, v) {
			storage[k] = String(v);
		},
		removeItem: function (k) {
			delete storage[k];
		}
	};

	const log = loadFwliveModule('log');
	const constants = loadFwliveModule('constants');
	const css = loadFwliveModule('css');
	const tint = loadFwliveModule('tint');
	const chips = loadFwliveModule('chips', { log: log });
	const links = loadFwliveModule('links', { log: log });
	const logging = loadFwliveModule('logging', {
		log: log,
		links: links,
		E: luciE.E,
		_: fakeGettext,
		localStorage: localStorage
	});
	const table = loadFwliveModule('table', { log: log, links: links });
	const buffer = loadFwliveModule('buffer');
	const hostname = loadFwliveModule('hostname');
	const pollCoordinator = loadFwliveModule('poll-coordinator');
	const proto = loadFwliveModule('proto', { document: document });
	const renderPolicy = loadFwliveModule('render-policy');
	const renderScheduler = loadFwliveModule('render-scheduler');

	const pollOps = [];
	const requestAnimationFrame =
		typeof options.requestAnimationFrame === 'function'
			? options.requestAnimationFrame
			: function() { return 0; };
	const cancelAnimationFrame =
		typeof options.cancelAnimationFrame === 'function' ? options.cancelAnimationFrame : null;
	const poll = {
		add: function(fn, interval) {
			pollOps.push({ op: 'add', interval: interval });
			this._fn = fn;
			this._interval = interval;
		},
		remove: function() {
			pollOps.push({ op: 'remove' });
		},
		ops: function() {
			return pollOps.slice();
		},
		clearOps: function() {
			pollOps.length = 0;
		}
	};
	const view = {
		extend: function(desc) { return desc; }
	};
	const rpc = {
		declare: function(cfg) {
			const key = cfg.object + '.' + cfg.method;
			const expect = cfg.expect;
			return async function() {
				let raw;
				if (rpcMocks[key])
					raw = await rpcMocks[key].apply(null, arguments);
				else if (typeof options.defaultRpc === 'function')
					raw = await options.defaultRpc(key, arguments);
				else
					raw = defaultRpcReply(key);
				if (Object.prototype.hasOwnProperty.call(rawRpcKeys, key)) return raw;
				return applyExpect(raw, expect);
			};
		}
	};

	const windowListeners = Object.create(null);
	const win = {
		addEventListener: function(type, fn) {
			if (!windowListeners[type]) windowListeners[type] = [];
			windowListeners[type].push(fn);
		},
		removeEventListener: function(type, fn) {
			const listeners = windowListeners[type] || [];
			const index = listeners.indexOf(fn);
			if (index !== -1) listeners.splice(index, 1);
		},
		requestAnimationFrame: requestAnimationFrame,
		cancelAnimationFrame: cancelAnimationFrame
	};

	const src = fs.readFileSync(VIEW_PATH, 'utf8');
	const body = src
		.replace(/^'use strict';\s*/m, '')
		.replace(/^\/\*[\s\S]*?\*\/\s*/m, '')
		.replace(/^'require [^']+';[^\n]*\n/gm, '');

	const fn = new Function(
		'view', 'poll', 'rpc', 'log', 'constants', 'css', 'tint', 'chips', 'logging',
		'table', 'buffer', 'hostname', 'proto', 'pollCoordinator', 'renderPolicy', 'renderScheduler', 'E', '_', 'document', 'window', 'localStorage',
		'performance', 'requestAnimationFrame', 'location',
		body
	);

	const viewDesc = fn(
		view, poll, rpc, log, constants, css, tint, chips, logging, table, buffer, hostname, proto,
		pollCoordinator, renderPolicy, renderScheduler,
		luciE.E, fakeGettext, document, win, localStorage,
		{ now: function() { return Date.now(); } },
		requestAnimationFrame, location
	);

	if (viewDesc.render) {
		const root = viewDesc.render();
		indexElementIds(root, harness.idMap);
		if (document.body && document.body.appendChild)
			document.body.appendChild(root);
	}

	return {
		view: viewDesc,
		document: document,
		window: win,
		localStorage: localStorage,
		location: location,
		poll: poll,
		rpcMocks: rpcMocks,
		setRpcMock: function(key, fn) {
			rpcMocks[key] = fn;
		},
		setHidden: function(hidden) {
			document.hidden = !!hidden;
			document.dispatchVisibility();
		},
		dispatchPagehide: function(event) {
			const listeners = (windowListeners.pagehide || []).slice();
			for (let i = 0; i < listeners.length; i++) listeners[i](event);
		}
	};
}

module.exports = {
	VIEW_PATH: VIEW_PATH,
	createHarnessDocument: createHarnessDocument,
	loadFwliveView: loadFwliveView
};

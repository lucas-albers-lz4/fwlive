/**
 * Mocked LuCI harness boot for view/status/fwlive.js (Tier 2 / #240 Wave B2).
 */
(function() {
	'use strict';

	const RES = '/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources';
	const baseclass = { extend: function(desc) { return desc; } };

	function gettext(s) {
		const out = Object(String(s));
		out.format = function() {
			let i = 0;
			const args = arguments;
			return String(out).replace(/%s|%d/g, function() {
				return String(args[i++]);
			});
		};
		return out;
	}

	if (typeof String.prototype.format !== 'function') {
		String.prototype.format = function() {
			let i = 0;
			const args = arguments;
			return String(this).replace(/%s|%d/g, function() {
				return String(args[i++]);
			});
		};
	}

	window._ = gettext;

	const CANNED_LOGS = [
		{ id: 1, time: 1704067200, msg: 'fw4: IN=wan OUT= SRC=192.0.2.1 DST=192.0.2.2 PROTO=TCP SPT=1234 DPT=443' },
		{ id: 2, time: 1704067201, msg: 'iptables: DROP IN=wan OUT= SRC=203.0.113.5 DST=192.168.1.1 PROTO=TCP DPT=22' },
		{ id: 3, time: 1704067202, msg: 'fw4: IN=wan OUT= SRC=192.0.2.3 DST=192.0.2.4 PROTO=UDP SPT=53 DPT=53' }
	];

	const rpcMocks = {
		'fwlive.poll': function() {
			return { log: CANNED_LOGS.slice() };
		},
		'fwlive.rules': function() {
			return { rules: { 'wan-lan': 'Allow LAN', 'block-wan': '!fw4: Block WAN' } };
		},
		'fwlive.resolve': function() {
			return { names: {} };
		},
		'fwlive.logging_status': function() {
			return {
				wan_zone: 'wan',
				wan_log: false,
				wan_log_limit: 10,
				nf_log_ipv4: true,
				nf_log_ipv6: false,
				ready: true,
				blockers: []
			};
		},
		'fwlive.enable_wan_logging': function() {
			return { ok: true, changed: true, wan_zone: 'wan' };
		},
		'fwlive.disable_wan_logging': function() {
			return { ok: true, changed: true, wan_zone: 'wan' };
		}
	};

	window.setFwlivePollMock = function(fn) {
		rpcMocks['fwlive.poll'] = fn;
	};

	const poll = { add: function() {}, remove: function() {} };
	const view = { extend: function(desc) { return desc; } };
	const rpc = {
		declare: function(cfg) {
			const key = cfg.object + '.' + cfg.method;
			return function() {
				const mock = rpcMocks[key];
				return Promise.resolve(mock ? mock.apply(null, arguments) : {});
			};
		}
	};

	async function loadModule(url, depNames, depValues) {
		const src = await fetch(url).then(function(r) {
			if (!r.ok)
				throw new Error('fetch failed: ' + url + ' (' + r.status + ')');
			return r.text();
		});
		const body = src
			.replace(/^'use strict';\s*/m, '')
			.replace(/^\/\*[\s\S]*?\*\/\s*/m, '')
			.replace(/^'require [^']+';[^\n]*\n/gm, '');
		const fn = new Function('baseclass', ...depNames, body);
		return fn(baseclass, ...depValues);
	}

	async function boot() {
		const log = await loadModule(RES + '/fwlive/log.js', [], []);
		const constants = await loadModule(RES + '/fwlive/constants.js', [], []);
		const css = await loadModule(RES + '/fwlive/css.js', [], []);
		const tint = await loadModule(RES + '/fwlive/tint.js', [], []);
		const links = await loadModule(RES + '/fwlive/links.js', ['log'], [log]);
		const buffer = await loadModule(RES + '/fwlive/buffer.js', [], []);
		const hostname = await loadModule(RES + '/fwlive/hostname.js', [], []);
		const chips = await loadModule(RES + '/fwlive/chips.js', ['log'], [log]);
		const proto = await loadModule(RES + '/fwlive/proto.js', ['document'], [document]);
		const table = await loadModule(RES + '/fwlive/table.js', ['log', 'links'], [log, links]);
		const logging = await loadModule(RES + '/fwlive/logging.js', ['log', 'links', 'E', '_'], [log, links, E, gettext]);

		const viewSrc = await fetch(RES + '/view/status/fwlive.js').then(function(r) {
			return r.text();
		});
		const viewBody = viewSrc
			.replace(/^'use strict';\s*/m, '')
			.replace(/^\/\*[\s\S]*?\*\/\s*/m, '')
			.replace(/^'require [^']+';[^\n]*\n/gm, '');
		const viewFn = new Function(
			'view', 'poll', 'rpc', 'log', 'constants', 'css', 'tint', 'chips', 'logging',
			'table', 'buffer', 'hostname', 'proto', 'E', '_', 'document', 'window', 'localStorage',
			viewBody
		);
		const viewDesc = viewFn(
			view, poll, rpc, log, constants, css, tint, chips, logging, table, buffer, hostname, proto,
			E, gettext, document, window, localStorage
		);

		const mount = document.getElementById('fwlive-app');
		const root = viewDesc.render();
		mount.appendChild(root);
		viewDesc.addFooter();
		await viewDesc.load();
		viewDesc.renderRows(true);

		window.fwliveView = viewDesc;
		window.dispatchEvent(new Event('fwlive-harness-ready'));
	}

	boot().catch(function(err) {
		const el = document.getElementById('fwlive-boot-error');
		if (el) {
			el.style.display = 'block';
			el.textContent = String(err && err.stack ? err.stack : err);
		}
		throw err;
	});
})();

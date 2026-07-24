'use strict';
'require baseclass';
'require fwlive.links as links';

/**
 * Logging toolbar and empty-state DOM renderers for luci-app-fwlive.
 *
 * renderToolbar(host, state, callbacks) → void
 *   host      - #fwlive-logging-bar element (cleared and rebuilt; element kept)
 *   state     - shallow copy: { loggingStatus, loggingBusy, entriesLength,
 *                               loggingNotice }
 *   callbacks - { onEnable(), onDisable() }  (async handlers OK; invoked fire-and-forget)
 *
 * renderManualTestNodes(host, state, callbacks) → void
 *   host      - <ul> element inside #fwlive-help (cleared and rebuilt)
 *   state     - shallow copy: { firewallBackend }
 *   callbacks - {} (unused; present for API consistency)
 *
 * Empty-state helpers:
 *   buildEmptyStateNodes(state, callbacks) → Node[]
 *   renderEmptyState(host, state, callbacks) → void
 *     host      - #fwlive-empty element
 *     state     - same as renderToolbar state
 *     callbacks - { onEnable() }
 *
 * Modules must not mutate state. host is cleared then rebuilt (idempotent replace).
 */

function blockerCode(state) {
	const blockers = (state.loggingStatus && state.loggingStatus.blockers) || [];
	if (blockers.indexOf('no_wan_zone') >= 0)
		return 'no_wan_zone';
	if (blockers.indexOf('nf_log_ipv4_missing') >= 0 ||
	    blockers.indexOf('nf_log_ipv6_missing') >= 0)
		return 'nf_log_missing';
	return '';
}

function renderToolbar(host, state, callbacks) {
	host.innerHTML = '';
	const st = state.loggingStatus;
	if (!st) {
		host.style.display = 'none';
		return;
	}

	if (!st.wan_log && state.entriesLength === 0) {
		host.style.display = 'none';
		return;
	}

	host.style.display = 'flex';
	const blocker = blockerCode(state);

	if (blocker === 'no_wan_zone') {
		host.appendChild(E('span', { 'class': 'fwlive-logging-status' },
			_('WAN logging unavailable: no WAN zone')));
		host.appendChild(links.firewallZonesLink());
		return;
	}

	if (blocker === 'nf_log_missing') {
		host.appendChild(E('span', { 'class': 'fwlive-logging-status' },
			_('WAN logging unavailable: missing kernel log modules')));
		return;
	}

	const limit = st.wan_log_limit || _('default 10/minute');
	if (st.wan_log) {
		host.appendChild(E('span', { 'class': 'fwlive-logging-status' }, [
			_('WAN logging on ('),
			E('a', {
				'href': '#fwlive-help',
				'class': 'fwlive-filter-link',
				'title': _('This is the firewall zone log_limit. fwlive only displays events after fw3/fw4 applies this rate cap.'),
				'click': function(ev) {
					const help = document.getElementById('fwlive-help');
					if (ev && ev.preventDefault)
						ev.preventDefault();
					if (help) {
						help.open = true;
						help.scrollIntoView({ block: 'nearest' });
					}
				}
			}, limit),
			_(')')
		]));
		host.appendChild(E('button', {
			'class': 'cbi-button cbi-button-action',
			'type': 'button',
			'disabled': state.loggingBusy ? '' : null,
			'click': function() { callbacks.onDisable(); }
		}, state.loggingBusy ? _('Disabling…') : _('Disable logging')));
		return;
	}

	host.appendChild(E('span', { 'class': 'fwlive-logging-status' },
		_('WAN logging off')));
	host.appendChild(E('button', {
		'class': 'cbi-button cbi-button-action',
		'type': 'button',
		'disabled': state.loggingBusy ? '' : null,
		'click': function() { callbacks.onEnable(); }
	}, state.loggingBusy ? _('Enabling…') : _('Enable logging')));
}

function buildEmptyStateNodes(state, callbacks) {
	const nodes = [];
	const st = state.loggingStatus;
	const blocker = blockerCode(state);

	if (state.loggingNotice) {
		nodes.push(E('p', { 'class': 'fwlive-logging-notice' }, [
			state.loggingNotice,
			' ',
			links.firewallZonesLink()
		]));
	}

	if (blocker === 'no_wan_zone') {
		nodes.push(E('p', {}, [
			_('No WAN firewall zone found in /etc/config/firewall. Configure zones under '),
			links.firewallZonesLink()
		]));
		return nodes;
	}

	if (blocker === 'nf_log_missing') {
		nodes.push(E('p', {}, _('Kernel netfilter log modules are missing. Install kmod-nf-log-ipv4 and kmod-nf-log-ipv6 (or kmod-nf-log / kmod-nf-log6), then reload the firewall.')));
		nodes.push(E('p', {}, [
			E('code', {}, 'opkg update && opkg install kmod-nf-log-ipv4 kmod-nf-log-ipv6')
		]));
		return nodes;
	}

	if (st && st.wan_log) {
		nodes.push(E('p', {}, _('Logging is enabled on WAN. Waiting for firewall events — blocked inbound traffic appears here (not normal LAN browsing).')));
		nodes.push(E('p', {}, links.firewallZonesLink(_('Open firewall zone settings'))));
		return nodes;
	}

	nodes.push(E('p', {}, _('No firewall events yet. OpenWrt does not log firewall traffic until you turn it on.')));
	nodes.push(E('p', {}, _('Enable logging to record blocked inbound traffic on WAN (rate-limited). Normal LAN browsing is not logged.')));
	nodes.push(E('p', {}, [
		E('button', {
			'class': 'cbi-button cbi-button-action',
			'type': 'button',
			'disabled': state.loggingBusy ? '' : null,
			'click': function() { callbacks.onEnable(); }
		}, state.loggingBusy ? _('Enabling…') : _('Enable logging')),
		' ',
		links.firewallZonesLink()
	]));
	return nodes;
}

function renderEmptyState(host, state, callbacks) {
	const nodes = buildEmptyStateNodes(state, callbacks);
	host.innerHTML = '';
	for (let i = 0; i < nodes.length; i++)
		host.appendChild(nodes[i]);
}

/**
 * renderManualTestNodes — fills a <li> host element with the backend-specific
 * manual test instruction. Call from addFooter() after render() has inserted
 * the placeholder <li id="fwlive-manual-test">.
 */
function renderManualTestNodes(host, state, _callbacks) {
	host.innerHTML = '';
	if (state.firewallBackend === 'iptables') {
		host.appendChild(document.createTextNode(_('Manual test (System → Terminal): ')));
		host.appendChild(E('code', {}, 'iptables -I INPUT -p icmp --icmp-type echo-request -j LOG --log-prefix "fwlive-ping: "'));
		host.appendChild(document.createTextNode(_(' then ping the router.')));
	} else {
		host.appendChild(document.createTextNode(_('Manual test (System → Terminal): ')));
		host.appendChild(E('code', {}, 'nft insert rule inet fw4 input ip protocol icmp icmp type echo-request log prefix "fwlive-ping " accept'));
		host.appendChild(document.createTextNode(_(' then ping the router.')));
	}
}

return baseclass.extend({
	renderToolbar: renderToolbar,
	buildEmptyStateNodes: buildEmptyStateNodes,
	renderEmptyState: renderEmptyState,
	renderManualTestNodes: renderManualTestNodes
});

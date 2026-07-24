'use strict';
'require baseclass';

/**
 * Shared view constants for luci-app-fwlive.
 * LuCI modules must return baseclass.extend(...) — plain objects fail Class.isSubclass.
 */
return baseclass.extend({
	ROW_LIMIT_OPTIONS: [ 25, 50, 100, 250, 500, 1000, 2000 ],
	DEFAULT_ROW_LIMIT: 100,
	FETCH_LINES_MAX: 2000,
	/* DOM budget: ~250 new/updated rows per second on typical LuCI routers */
	RENDER_CAP_PER_SEC: 250,
	VIEW_MODES: [ 'simple', 'detailed' ],
	COLUMN_SETS: {
		simple: [ 'action', 'time', 'iface', 'flow', 'proto', 'rule' ],
		detailed: [ 'time', 'action', 'rule', 'iface_in', 'iface_out', 'dir', 'proto', 'src', 'sport', 'dst', 'dport', 'flags', 'len', 'message' ]
	}
});

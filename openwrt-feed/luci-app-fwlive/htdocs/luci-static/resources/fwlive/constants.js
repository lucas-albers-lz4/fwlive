'use strict';

/**
 * Shared view constants for luci-app-fwlive (plain LuCI module export).
 * Phase 0 spike (#23): verify `'require fwlive.constants as constants'` resolves.
 */
return {
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
};

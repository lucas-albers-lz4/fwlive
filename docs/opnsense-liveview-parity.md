# OPNsense Live View Parity Matrix (for LuCI MVP)

**Context:** Parity is measured at **UI behavior** and **log-derived events**, not at PF vs nftables. OpenWrt uses nft/fw4; OPNsense uses PF — the portable layer is **firewall logging**. See **[`opnsense-liveview-understanding.md`](opnsense-liveview-understanding.md)** (PF vs nft, confidence, optional OPNsense source trace).

**Architecture:** Our package uses the **modern LuCI JS view** (`view.extend()`, JSON-RPC ubus). OPNsense’s PHP/Volt server UI is **not** ported — only interaction and layout patterns. Target mapping: **[`fwlive-ui-design-target.md`](fwlive-ui-design-target.md)**.

## Observed OPNsense behavior

- API polling endpoint: `/api/diagnostics/firewall/log` with `digest` + `limit`.
- Optional stream endpoint exists but poll mode is the default UI behavior.
- UI keeps an in-memory ring buffer, applies client-side filters, and refreshes every second.
- Field-level filters support contains/equal/not-contains/not-equal.
- Global quick search scans all visible fields.
- Action highlighting separates allow/pass vs deny/block style events.

## Staged roadmap

See **[`fwlive-development-plan.md`](fwlive-development-plan.md)** for stages, CLI test commands, and exit criteria.

## LuCI MVP parity mapping

- Implemented: poll-based live view with one-second refresh.
- Implemented: in-memory bounded history + visible-row caps.
- Implemented: quick search + field filters for action/interface/protocol/src/dst/ports.
- Implemented: URL hash filter persistence for shareable troubleshooting context.
- Implemented (stage 1): **firewall-only feed** — `isFirewallEvent()` drops dnsmasq/procd/etc.; CLI: `./scripts/fwlive-test.sh`.
- Implemented (stage 2): **schema hardening** — unix `timestamp`, normalized `action` enum, `interface_in`/`out`, `flags`, `length`; tests: `tests/fwlive-schema.test.js`.
- Deferred (stage 3): rule attribution (`tracking_id` → `rule_label`).
- Deferred (stage 4): pause/resume, 250/s render cap + suppression banner.
- Deferred (stage 5): advanced filter operators and tag UI.
- Deferred (stage 6): reverse DNS lookup and rule overlay / modal details.
- Deferred (stage 7): server-driven digest deltas and SSE streaming endpoint.
- Deferred: template CRUD for saved filter sets.

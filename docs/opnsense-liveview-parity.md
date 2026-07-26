# OPNsense Live View Parity Matrix (for LuCI MVP)

**Context:** Parity is measured at **UI behavior** and **log-derived events**, not at PF vs nftables. OpenWrt uses nft/fw4; OPNsense uses PF — the portable layer is **firewall logging**. The useful comparison is what appears in firewall logs, not PF-vs-nft rule translation.

**Architecture:** Our package uses the **modern LuCI JS view** (`view.extend()`, JSON-RPC ubus). OPNsense’s PHP/Volt server UI is **not** ported — only interaction and layout patterns. Target mapping: **[`fwlive-ui-design-target.md`](fwlive-ui-design-target.md)**.

## Observed OPNsense behavior

- API polling endpoint: `/api/diagnostics/firewall/log` with `digest` + `limit`.
- Optional stream endpoint exists but poll mode is the default UI behavior.
- UI keeps an in-memory ring buffer, applies client-side filters, and refreshes every second.
- Field-level filters support contains/equal/not-contains/not-equal.
- Global quick search scans all visible fields.
- Action highlighting separates allow/pass vs deny/block style events.

## Staged roadmap

See **[ROADMAP.md](ROADMAP.md)** for stages, CLI test commands, and exit criteria.

## LuCI MVP parity mapping

- Implemented: poll-based live view with one-second refresh.
- Implemented: in-memory bounded history + visible-row caps.
- Implemented: quick search + field filters for action/interface/protocol/src/dst/ports.
- Implemented: URL hash filter persistence for shareable troubleshooting context.
- Implemented (stage 1): **firewall-only feed** — `isFirewallEvent()` drops dnsmasq/procd/etc.; CLI: `./scripts/fwlive-test.sh`.
- Implemented (stage 2): **schema hardening** — unix `timestamp`, normalized `action` enum, `interface_in`/`out`, `flags`, `length`; tests: `tests/fwlive-schema.test.js`.
- Implemented (stage 3): `rule_hint` from log prefix; LuCI **Rule** column (click filters).
- Implemented (stage 3.3): Rule links to firewall admin (`fw4` → traffic rules; else nftables).
- Implemented (stage 3.4b): UCI rule name resolve (`rule_label`) via `ubus fwlive rules`.
- Implemented (stage 4): **pause/resume** — buffer ingests while table frozen; resume redraws; message wrap/one-line toggle.
- Implemented (stage 4b): **auto-refresh** checkbox + **limit** dropdown (25…2000, default 100).
- Implemented (stage 4.5): 250/s render cap + suppression banner (token bucket).
- Deferred: session running-total / rate counter (not in OPNsense limit spec).
- Implemented (stage 5, partial): click-to-filter (src/dst/proto/iface/action); filter chip bar with clear.
- **Deliberate difference:** **Simple / Detailed toggle** (single **Show Detail** button) — OPNsense uses one table layout; we default to a compact Simple grid and optional Detailed 14-column forensic view ([`fwlive-ui-design-target.md`](fwlive-ui-design-target.md) § View modes).
- Implemented (stage 5.6): advanced filter operators (`!` prefix for is-not/not-contains); token array tests.
- Implemented (stage 6, partial): **Show hostnames** checkbox (default off) + `ubus fwlive resolve`.
- Deferred (stage 6): rule overlay / modal details.
- Implemented (stage 7, partial): server-side firewall-only read via `ubus fwlive poll`.
- Deferred (stage 7): digest deltas and SSE streaming endpoint.
- Deferred: template CRUD for saved filter sets.

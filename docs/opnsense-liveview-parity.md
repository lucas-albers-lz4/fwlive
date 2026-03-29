# OPNsense Live View Parity Matrix (for LuCI MVP)

**Context:** Parity is measured at **UI behavior** and **log-derived events**, not at PF vs nftables. OpenWrt uses nft/fw4; OPNsense uses PF — the portable layer is **firewall logging**. See **[`opnsense-liveview-understanding.md`](opnsense-liveview-understanding.md)** (PF vs nft, confidence, optional OPNsense source trace).

## Observed OPNsense behavior

- API polling endpoint: `/api/diagnostics/firewall/log` with `digest` + `limit`.
- Optional stream endpoint exists but poll mode is the default UI behavior.
- UI keeps an in-memory ring buffer, applies client-side filters, and refreshes every second.
- Field-level filters support contains/equal/not-contains/not-equal.
- Global quick search scans all visible fields.
- Action highlighting separates allow/pass vs deny/block style events.

## LuCI MVP parity mapping

- Implemented: poll-based live view with one-second refresh.
- Implemented: in-memory bounded history + visible-row caps.
- Implemented: quick search + field filters for action/interface/protocol/src/dst/ports.
- Implemented: URL hash filter persistence for shareable troubleshooting context.
- Deferred: template CRUD for saved filter sets.
- Deferred: reverse DNS lookup and per-row rich modal details.
- Deferred: server-driven digest deltas and SSE streaming endpoint.

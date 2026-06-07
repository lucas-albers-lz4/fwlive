# Firewall Live View — UI design target (LuCI client-side)

How we pursue **OPNsense Live View** look-and-feel and interaction patterns on OpenWrt, without porting OPNsense’s server stack.

**Related:** [staged plan](fwlive-development-plan.md) · [parity matrix](opnsense-liveview-parity.md) · [logging model](opnsense-liveview-understanding.md) · [event schema](openwrt-fwlive-schema.md)

---

## Architectural target (what we are building)

`luci-app-fwlive` is a **pure client-side LuCI JavaScript view** on the modern framework:

| Piece | Role | OPNsense analogue |
| ----- | ---- | ----------------- |
| [`fwlive.js`](../openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js) | `view.extend()` — layout, polling, DOM updates, filter UX | Volt/HTML layout + page JS |
| [`fwlive/log.js`](../openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js) | Parsing, normalization, client-side filter predicates | Server/JS log parsing module |
| [`core/fwlive-log.js`](../core/fwlive-log.js) | Node test twin of `log.js` (CLI + unit tests) | — |
| `rpc.declare({ object: 'log', method: 'read' })` | JSON-RPC → **ubus** via **rpcd** | `/api/diagnostics/firewall/log` |
| `menu.d` + `rpcd` ACL JSON | Declarative menu + permissions | PHP routing + ACL |

We **do not** use legacy Lua CBI views (`luasrc/controller`, `cbi.Map`). We **do not** need OPNsense’s PHP/Volt engine. Design patterns port **into the browser**: poll, parse, filter, render.

**Data path (fixed):** nft/fw4 `log` → kernel printk → logd → `ubus log.read` → client parser → table.

---

## Module responsibilities

### `fwlive.js` — UI shell

- **`render()`** — static chrome: filter bar, pause control, scroll region, sticky table header (via `E()`).
- **`load()` / `pollData()`** — 1s poll; respect `paused` (stage 4).
- **`renderRows()`** — map normalized rows → table cells; action styling; click-to-filter anchors (stage 5).
- **State:** `entries[]` ring buffer, `activeFilters[]` or form/hash filters, `paused`, scroll preservation.

### `fwlive/log.js` — log brain

- **`isFirewallEvent()`** — stage-1 noise gate.
- **`normalizeEntry()`** — stage-2 schema (`src`, `dst`, `interface_in`, `action`, …).
- **`matchesFilter()`** — client-side predicates (evolve toward token AND logic in stage 5).
- **Display helpers** — `formatTimestampLocal()`, `formatMessageDisplay()`, `actionRowClass()` (presentation only).

Keep **`core/fwlive-log.js` in sync** for every parser/filter change (`./scripts/fwlive-test.sh`).

---

## Visual layout (“the look”) — evaluation

Suggestions to replicate OPNsense’s clean tabular Live View, adapted for LuCI.

| Suggestion | Verdict | Our approach |
| ---------- | ------- | ------------ |
| Build layout in `render()` with `E()` | **Adopt** | Already in use; extend with control bar + badge styling. |
| Map `pass`/`drop` to green/red typography | **Adopt (adapted)** | Use LuCI-friendly classes: custom `.fwlive-pass` / `.fwlive-deny` (done) or map to `text-success` / `text-danger` where theme-consistent. Optional unicode/icon prefix (✔/✖) — low priority, test contrast in dark themes. |
| Sticky header + scroll body | **Adopt** | `#fwlive-scroll` + `position: sticky` on `thead` (done). |
| Pause / Play top bar | **Adopt** | Stage 4: `this.paused`; polling continues fetching but `renderRows` skipped; show “buffering N events” hint. |
| Primary columns: Action, Time, Interface, Src/Dst, Rule | **Adopt (phased)** | Most columns exist. **Rule Info** = stage 3. Consider a combined **Src → Dst** column later to reduce width (optional polish). |
| Interface as small grey badges | **Adopt** | Stage 4/5 polish: `E('span', { 'class': 'label' }, iface)` on `interface_in` / `out`. |
| Time as `HH:MM:SS` only | **Defer** | Local `YYYY-MM-DD HH:MM:SS` today; add compact time mode or drop date when all rows are “today”. |

**Not a goal:** pixel-perfect clone of OPNsense Bootstrap markup. Goal: **same operator affordances** (scan, filter, pause, attribute) inside LuCI’s `cbi-map` / table conventions.

---

## Tokenized filtering (“the features”) — evaluation

| Suggestion | Verdict | Our approach |
| ---------- | ------- | ------------ |
| Click IP/interface/action → add filter token | **Adopt** | Stage 5. Wrap cell text in `E('a', { click: … })` or LuCI `ui.createActionHandler`; append `{ field, op, value }` to `activeFilters`. |
| `data-filter-field` / `data-filter-val` anchors | **Adapt** | Same idea; prefer LuCI click handlers over raw `href="#"` where possible. |
| AND semantics across active tokens | **Adopt** | Extend `matchesFilter()` to accept token array; today: single form fields + quick search (OR across fields via `q`). |
| Filter **client-side only** (no ubus filter args) | **Adopt** | **Already correct.** `log.read` returns recent lines; cheap on router; parser drops noise. |
| Slice to visible row cap after filter | **Adopt** | `visibleRows` (200) after filter; OPNsense ~50 — tunable constant. |

**Current MVP:** text inputs + URL hash persistence. **Target:** visual filter tags + click-to-filter, per stage 5 in [fwlive-development-plan.md](fwlive-development-plan.md).

---

## Rule ID / rule navigation — evaluation

| Suggestion | Verdict | Our approach |
| ---------- | ------- | ------------ |
| Rule column with human label | **Adopt** | Stage 3: `rule_label` from nft/fw4 metadata. |
| nft `comment`, handle, or log prefix | **Adapt** | Prefer **fw4 rule name** / UCI `@name` when resolvable; fallback: nft handle or log `prefix "…"`. |
| Deep link to firewall config | **Adopt (lightweight)** | Link to `admin/status/nftables` or `admin/network/firewall` with hash/query when we have a stable rule key — **best-effort**, not 1:1 with OPNsense RID. |
| `meta nftrace` / tracking id | **Investigate** | Only if log lines expose stable ids on OpenWrt 24.10; document findings in stage 3 notes. |

OpenWrt will **not** mirror OPNsense PF rule IDs. Parity is **“jump toward the rule that likely generated this log”**, not identical RID badges.

---

## License and attribution — evaluation

| Suggestion | Verdict | Our approach |
| ---------- | ------- | ------------ |
| BSD header because we “copy appearance” | **Adapt — do not overstate** | `luci-app-fwlive` is **Apache-2.0** (see `Makefile`). We implement **original** LuCI JS inspired by OPNsense **UX**, not a port of OPNsense PHP/JS sources. |
| Attribution comment in `fwlive.js` | **Adopt** | Short top-of-file note: *UI interaction patterns inspired by OPNsense Live View (2-clause BSD).* No claim of code derivation unless we actually import their files. |
| Copy OPNsense Volt/JS verbatim | **Reject** | Reimplement with `view.extend()` + `E()`; keeps licenses clean and fits LuCI. |

If we later import **substantial** OPNsense-licensed code, add explicit BSD notice for **those files** per the license terms.

---

## Implementation map (stages ↔ UI work)

| Stage | UI deliverable |
| ----- | -------------- |
| 1–2 (done) | Firewall-only feed, schema columns, basic table + filters |
| Formatting pass (done) | Local time, scroll box, sticky header, compact message, status line |
| 3 | **Rule Info** column + optional deep link |
| 4 | Pause/Play bar, ring-buffer indicator, flood banner |
| 5 | Tokenized filters, click-to-filter, filter tag chips |
| 6 | DNS hover, rule detail drawer |
| 7 | Optional digest/SSE (transport); UI unchanged or thinner polls |

---

## Verification

- **CLI gate (every stage):** `./scripts/fwlive-test.sh`, `./scripts/fwlive-ubus-read.sh`
- **UI gate (QEMU lab):** `./scripts/qemu-install-fwlive.sh` → LuCI **Status → Firewall Live View** with nft log rules ([fwlive-nft-logging.md](fwlive-nft-logging.md))
- **Acceptance:** [fwlive-acceptance.md](fwlive-acceptance.md)

---

## Summary

We target **OPNsense Live View operator experience** on a **LuCI client-side architecture**: `fwlive.js` owns the grid and controls; `fwlive/log.js` owns parsing and in-memory filtering; **ubus** stays a dumb recent-log pipe. Suggestions about Volt, PHP APIs, and server-side filtering **do not apply**; suggestions about sticky grids, pause, token filters, and rule attribution **do apply**, phased per the staged plan.

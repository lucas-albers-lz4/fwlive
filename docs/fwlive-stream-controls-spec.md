# Stream controls spec — evaluation (OPNsense parity)

How OPNsense Live View **auto-refresh** and **row limit** map onto `luci-app-fwlive` (`fwlive.js`).  
**No code change in this doc** — schedule and design target only.

**Related:** [ROADMAP.md](ROADMAP.md) · [fwlive-development-plan.md](fwlive-development-plan.md) · [fwlive-ui-design-target.md](fwlive-ui-design-target.md)

---

## What OPNsense provides

| Control | Behavior |
| ------- | -------- |
| **Auto-refresh** checkbox | Unchecked = freeze grid; checked = resume ~1s poll |
| **Limit** dropdown | Client buffer size: 25, 50, 100 (default), 250, 500, … up to **1000–2000** |
| **Performance note** | \>2000 DOM rows → browser stutter; hard upper cap |

---

## What we have today (`fwlive.js`)

| Property | Current value | Role |
| -------- | ------------- | ---- |
| `paused` | Pause / **Resume** button | Frozen table DOM; **polling still runs**; `entries[]` keeps growing to `maxHistory` |
| `maxHistory` | **2000** (fixed) | `log.read` lines requested; dedupe ring buffer |
| `visibleRows` | **200** (fixed) | Max rows drawn after filters |
| `messageLayout` | wrap / one-line toggle | Layout only (already shipped) |

**Dynamic view:** Already live — 1s poll, new nft log lines appear, status shows `Showing N of M events`. Not a running packet **counter**; event **tail** only.

---

## Spec vs implementation — evaluation

| Suggestion | Verdict | Our plan |
| ---------- | ------- | -------- |
| `isPaused` / auto-refresh checkbox | **Adopt (UI)** | Stage **4b.1** — add **Auto-refresh** checkbox in toolbar (checked = live). Keep or replace Pause button (same state). |
| Drop/stash poll responses when paused (`if (paused) return`) | **Reject** | We **keep fetching** while paused so ingest buffer grows (up to 2000 events); **Limit** is the live display cap only. |
| `rowLimit` dropdown (25…2000) | **Adopt** | Stage **4b.2** — user-selectable cap; persist in `localStorage`. |
| Single dropdown drives one buffer | **Adapt** | Limit caps **stored firewall events** + DOM rows (`maxHistory`, `visibleRows`). **`log.read`** always requests up to **2000** raw lines — firewall lines are sparse in logd. |
| Default limit **100** | **Adopt** | New default when dropdown ships; options: **25, 50, 100, 250, 500, 1000, 2000**. |
| Hard cap **2000** | **Adopt** | No option above 2000; tooltip/warning if user had saved higher. |
| `E()` checkbox + `<select>` in toolbar | **Adopt** | Same `fwlive-toolbar` as Pause / Message layout. |
| `slice(0, rowLimit)` on raw packets before DOM | **Adapt** | Apply after `filterLogEntries` + filter: `entries.slice(-maxHistory)`, render `filtered.slice(-visibleRows)`. |

---

## Stage 4b — scheduled substeps

| Step | Deliverable | Accept |
| ---- | ----------- | ------ |
| **4b.1** | **Auto-refresh** checkbox (OPNsense label); wired to `paused` (inverted) | Uncheck freezes table; buffer count still increases; re-check resumes |
| **4b.2** | **Limit** dropdown; `maxHistory` + `visibleRows` follow selection | Select 100 → ≤100 rows in buffer and table; 2000 max |
| **4b.3** | Persist limit in `localStorage`; sane default **100** on first visit | Reload restores choice |
| **4b.4** | Status line shows limit + paused state clearly | e.g. `Paused — 142/500 events` |

**Deferred (stage 4 remainder):** render-rate token bucket + suppression banner (heavy flood).

**Out of scope (separate feature):** session **running total** / packets-per-second counter — not in OPNsense limit spec; backlog if needed.

---

## Toolbar target layout (after 4b)

```
[ Auto-refresh ☑ ]  [ Limit ▼ 100 ]  [ Pause ]  [ Message: wrap ]  status text…
```

Pause button may merge into Auto-refresh only (one control) in 4b.1 — pick during implementation.

---

## Verification

```sh
./scripts/qemu-install-fwlive.sh
./scripts/fwlive-nft-ping-log.sh add --ssh
ssh -p 2222 root@127.0.0.1 'ping 127.0.0.1'   # continuous
```

LuCI: uncheck auto-refresh → table frozen, status buffer climbs; set limit 50 → row count bounded; restore auto-refresh → live tail resumes.

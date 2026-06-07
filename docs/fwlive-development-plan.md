# Firewall Live View — staged development plan

Roadmap from current MVP (generic `log.read` table) toward OPNsense Live View parity. Each stage is **deployable** and **verifiable from the shell** without opening a browser.

**References:** [UI design target](fwlive-ui-design-target.md) · [OPNsense parity matrix](opnsense-liveview-parity.md) · [event schema](openwrt-fwlive-schema.md) · [nft logging](fwlive-nft-logging.md)

## Design principles

1. **Portable layer = firewall log lines** (not PF↔nft rule translation).
2. **Client-side LuCI JS** (`view.extend()` + `rpc.declare` → ubus) — not legacy Lua CBI; not OPNsense PHP/Volt. See [fwlive-ui-design-target.md](fwlive-ui-design-target.md).
3. **Source of truth for parsing/filter logic:** [`core/fwlive-log.js`](../core/fwlive-log.js) (Node); LuCI [`fwlive/log.js`](../openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js) mirrors it for the UI; [`fwlive.js`](../openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js) owns layout and polling.
4. **CLI-first tests** on every stage; LuCI is a thin consumer of the same rules.
5. **Small deployable steps** — ship after each stage passes `scripts/fwlive-test.sh`.

## Command-line test approach

| Command | Purpose |
|---------|---------|
| `./scripts/fwlive-test.sh` | Run all automated tests (parser, firewall filter, fixtures, bench) |
| `node core/fwlive-log.js filter < tests/fixtures/logread-mixed.json` | Print normalized **firewall-only** rows from fixture |
| `node core/fwlive-log.js stats < tests/fixtures/logread-mixed.json` | Count total vs firewall vs noise |
| `./scripts/fwlive-ubus-read.sh` | Live device: `ubus fwlive poll` → firewall-only JSON (SSH) |

Fixture shape matches `ubus call log read` output:

```json
{ "log": [ { "time": 1717675740, "msg": "..." } ] }
```

On a running OpenWrt guest (QEMU or Docker):

```sh
./scripts/fwlive-ubus-read.sh --lines 50
# or after enabling nft log rules:
./scripts/fwlive-ubus-read.sh --lines 50 | jq '.[0]'
```

No browser required until you explicitly want UI regression checks.

---

## Stage 1 — Firewall-only feed (done)

**Problem:** UI shows all `logread` traffic (dnsmasq, procd, …) as `UNKNOWN`.

**Deliverables**

- `isFirewallEvent()` heuristic in `core/fwlive-log.js`
- LuCI `fetchEntries()` skips non-firewall lines
- Fixtures + tests proving noise is dropped and nft/fw4 lines are kept
- `scripts/fwlive-test.sh`, `scripts/fwlive-ubus-read.sh`

**Exit criteria**

- `./scripts/fwlive-test.sh` passes
- `stats` on `logread-mixed.json`: firewall count > 0, noise excluded
- Empty table when no firewall-shaped lines (not full syslog dump)

---

## Stage 2 — Schema hardening (done)

**Goal:** Align normalized rows with the [functional spec](opnsense-liveview-parity.md) data matrix (subset achievable from Linux netfilter logs).

| Field | Work |
|-------|------|
| `interface_in` / `interface_out` | Split `IN=` / `OUT=` instead of single `interface` |
| `action` | Map to `pass` / `block` / `drop` / `reject` enum + keep raw |
| `flags`, `length` | Parse when present in message (`LEN=`, TCP flags text) |
| `timestamp` | Unix epoch integer in API; ISO only for display |

**Tests:** extend fixtures with real `nft` / kernel log samples; schema assertions in `tests/fwlive-schema.test.js`.

**Exit criteria:** CLI `filter` output includes new fields; acceptance doc updated.

---

## Stage 3 — Rule attribution (incremental)

**Goal:** `rule_hint` from log prefix → later `rule_label` via fw4/UCI resolve.

| Step | Status |
|------|--------|
| 3.1 `parseRuleHint()` → `rule_hint` field | **done** |
| 3.2 LuCI **Rule** column (click → quick search) | **done** |
| 3.3 Deep link to firewall/nftables admin | **done** |
| 3.4b `rpcd` resolve hint → UCI rule name (`ubus fwlive rules`) | **done** |

**Tests:** `fwlive-parser-filter.test.js` (fwlive-ping, fw4, fwlive-test prefixes).

**Exit criteria (3.1–3.2):** CLI/ubus-read JSON includes `rule_hint`; LuCI Rule column populated on prefixed nft rules.

---

## Stage 4 — Stream control & flood safety (core done)

**Goal:** Pause/resume viewport; background buffer; rate limit UI.

| Feature | Spec target | Implementation sketch | Status |
|---------|-------------|-------------------------|--------|
| Pause/Resume | Viewport frozen, buffer ingests | `paused` flag; skip `renderRows`, keep `fetchEntries` | **done** |
| Message layout | wrap vs one-line | `messageLayout` + toolbar toggle | **done** |
| Ring buffer | 1,000 default | Configurable `maxHistory` (env or LuCI setting) | fixed 2000 |
| Render cap | 250 new events/sec + banner | Token bucket charges **per-poll new events**, not full row count | **done** |

**Exit criteria (core):** Pause/Resume button in toolbar; status line shows buffer count while paused; resume redraws.

**Tests:** pause state is UI-only for now; render-cap token bucket test deferred with flood banner.

### Stage 4b — OPNsense stream controls (planned)

Full evaluation: [fwlive-stream-controls-spec.md](fwlive-stream-controls-spec.md).

| Step | Work | Status |
|------|------|--------|
| 4b.1 | **Auto-refresh** checkbox (OPNsense label); maps to `paused` | **done** |
| 4b.2 | **Limit** dropdown 25…2000; drives `maxHistory` + `visibleRows` | **done** |
| 4b.3 | Persist limit in `localStorage`; default **100** | **done** |
| 4b.4 | Status: `shown/limit` + paused hint | **done** |

**Deliberate difference from naive spec:** we do **not** stop polling while paused — buffer keeps ingesting so Resume shows traffic that arrived during inspection.

---

## Stage 5 — Advanced filtering (incremental)

**Goal:** OPNsense-style filter constructor — **small shippable steps** ([ROADMAP.md](ROADMAP.md)).

| Step | Status |
|------|--------|
| 5.0 Infer `pass` on silent nft log lines | **done** |
| 5.1 Click src/dst → filter field | **done** |
| 5.2 Click proto/iface/action | **done** |
| 5.3 Filter chip bar | **done** |
| 5.4 AND `matchesFilter()` light Node test | **done** |

| 5.6 `!` prefix operators (is not / not contains) | **done** |

Later: saved filter templates.

**Tests:** one fixture per parser step in `fwlive-test.sh`; LuCI smoke on QEMU.

---

## Stage 6 — Inspect & enrichment

**Goal:** Operator tooling without leaving the grid.

| Step | Status |
|------|--------|
| **6.1** Show hostnames checkbox (default off) + `ubus fwlive resolve` | **done** |
| Rule overlay: raw rule config for `tracking_id` | backlog |
| Optional row detail drawer | backlog |

**Tests:** `qemu-smoke-fwlive.sh` (`fwlive resolve`); LuCI smoke with checkbox enabled.

---

## Validation matrix (infrastructure)

**Goal:** One parameterized path to build and smoke-test **every supported OpenWrt version** on **x86** and **armsr** lab targets — without duplicating the 23.05 one-off script.

| Step | Script | Status |
|------|--------|--------|
| Baseline gate (parser + script checks) | `./scripts/validate-baseline.sh` | **done** |
| Single cell (version + qemu + sdk) | `./scripts/validate-openwrt.sh --version VER` | **done** |
| All versions build (no QEMU) | `./scripts/validate-openwrt-all.sh build` | **done** |
| All versions x86 smoke | `./scripts/validate-openwrt-all.sh smoke-x86` | **done** |
| Full SDK matrix | `validate-openwrt-all.sh build-full` / `docker-sdk.sh build-all` | **done** |
| **25.12** in SDK + validation matrix | `sdk-matrix.sh` → 25.12.0 | **done** |

**Phased use:** baseline → build all versions → smoke **24.10 x86** (reference) → `smoke-x86` for all → armsr sign-off per release.

Spec: [`validation-matrix.md`](validation-matrix.md).

---

## Stage 7 — Transport efficiency (post-MVP)

**Goal:** Sub-second updates at scale.

| Step | Status |
|------|--------|
| **7.1** Server-side firewall-only read (`ubus fwlive poll` + `fwlive-log-filter.sh`) | **done** |
| Digest + incremental fetch (OPNsense-style) | backlog |
| Optional SSE / WebSocket stream | backlog |

**Note:** `fwlive poll` still reads the same logd ring via `log.read`; it only strips non-firewall lines from the JSON sent to LuCI. Line count is passed as `addresses[0]` (rpcd shell-plugin quirk). It does not recover firewall events evicted from the ring by syslog noise.

**Tests:** `tests/fwlive-shell-filter.test.js`; `qemu-smoke-fwlive.sh` (`fwlive poll`).

---

## Parity tracking

Update [opnsense-liveview-parity.md](opnsense-liveview-parity.md) as stages land:

| Stage | Parity items |
|-------|----------------|
| 1 | Firewall-only stream (fixes syslog noise) |
| 2 | Universal data matrix (partial) |
| 3 | Rule attribution |
| 4 | Pause/resume, ring buffer tuning, flood banner |
| 5 | Advanced filter UI |
| 6 | DNS hover, rule overlay |
| 7 | Digest/SSE, sub-second latency |

---

## Deploy loop per stage

```sh
./scripts/fwlive-test.sh
./scripts/docker-sdk.sh make          # or copy JS to running container for dev
./scripts/docker-rootfs-x86-install-fwlive.sh   # x86 experiment
# optional live check:
./scripts/fwlive-ubus-read.sh --lines 30
```

LuCI validation remains optional; CLI + ubus pipeline is the default gate.

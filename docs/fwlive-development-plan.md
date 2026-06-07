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
| `./scripts/fwlive-ubus-read.sh` | Live device: `ubus log.read` → firewall-only JSON (SSH) |

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

## Stage 3 — Rule attribution

**Goal:** Deterministic `tracking_id` → `rule_label` (human fw4/UCI rule name).

**Approach (incremental)**

1. Parse nft log prefixes / fw4 markers for handle or rule set hints.
2. Optional `rpcd`/`ubus` helper: resolve handle → `/etc/config/firewall` name (read-only).
3. Display `rule_label` column; CLI prints attribution or `unknown`.

**Tests:** fixture lines with known prefixes; mock rule map JSON for unit tests.

**Exit criteria:** attributed rows show label in CLI output; LuCI column added.

---

## Stage 4 — Stream control & flood safety

**Goal:** Pause/resume viewport; background buffer; rate limit UI.

| Feature | Spec target | Implementation sketch |
|---------|-------------|-------------------------|
| Pause/Resume | Viewport frozen, buffer ingests | `paused` flag; skip `renderRows`, keep `fetchEntries` |
| Ring buffer | 1,000 default | Configurable `maxHistory` (env or LuCI setting) |
| Render cap | 250 events/sec + banner | Token bucket in `renderRows`; show suppression notice |

**Tests:** simulate 500 events/sec in Node; assert cap + banner flag without DOM (pure state machine test).

---

## Stage 5 — Advanced filtering

**Goal:** OPNsense-style filter constructor.

- Operators: `is`, `is not`, `contains`, `starts with`
- Visual filter tags with AND semantics
- Keep URL hash persistence

**Tests:** `matchesFilter()` matrix test — no browser.

---

## Stage 6 — Inspect & enrichment

**Goal:** Operator tooling without leaving the grid.

- Hover reverse DNS (async `dns.lookup` via `rpcd` or client-side if allowed)
- Rule overlay: raw rule config for `tracking_id`
- Optional row detail drawer

**Tests:** mock DNS/rpcd responses; CLI `enrich` subcommand.

---

## Stage 7 — Transport efficiency (post-MVP)

**Goal:** Sub-second updates at scale.

- Server-side firewall-only read (rpcd script filtering before JSON)
- Digest + incremental fetch (OPNsense-style)
- Optional SSE / WebSocket stream

**Tests:** digest round-trip fixtures; latency benchmark script.

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

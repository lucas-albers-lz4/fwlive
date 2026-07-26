# fwlive — structured roadmap

Product: **LuCI Firewall Live View** — OPNsense Live View–style operator UX on OpenWrt, client-side JS + `ubus fwlive.poll`.

**Architecture:** [fwlive-ui-design-target.md](fwlive-ui-design-target.md) · **Acceptance:** [fwlive-acceptance.md](fwlive-acceptance.md)

---

## Development approach (agreed)

- **Small steps** — ship one behavior at a time; accept in QEMU LuCI + one CLI check.
- **Light testing** — `./scripts/fwlive-test.sh` + manual browser smoke; no comprehensive suite required.
- **Backport awareness** — edge cases will surface on 23.05 / armsr; fix as we hit them.

**Test loop per step:**

```sh
./scripts/fwlive-test.sh                    # parser regressions
./scripts/qemu-install-fwlive.sh            # sync JS
# LuCI: http://localhost:8080/cgi-bin/luci/admin/status/fwlive
```

---

## Status summary (2026-06)

| Milestone | State | Notes |
| --------- | ----- | ----- |
| **MVP** | **Done** | Real nft logs on QEMU; stages 1–5 core, 4b, 3.4b; acceptance signed off |
| **Infra** | **Done** | QEMU x86 lab, `qemu-install-fwlive.sh`, nft ping helper |
| **Stage 4** | **Done (core)** | Pause/resume + buffer status; message layout toggle |
| **Stage 4b** | **Done** | Auto-refresh checkbox + row limit dropdown |
| **Stage 5** | **Done (core)** | Click-to-filter, chips, pass inference |
| **Stage 3** Rule attribution | **Done (core)** | rule_hint, Rule column, deep link |
| **Stage 6** | **Partial** | **Show hostnames** checkbox (default off) — `ubus fwlive resolve` |
| **Stage 7** | **Partial** | **`ubus fwlive poll`** — server-side firewall-only filter |
| **Stage 6–7 rest** | Backlog | Rule overlay, digest/SSE |

---

## Post-MVP priority

```
Stage 4 ✓ ──► Stage 5 ✓ ──► Stage 3 ✓ ──► Stage 4b ✓ ──► backport ✓ ──► publish prep ──► Stage 6+
```

**Next:** publish upstream · expand validation matrix sign-off (25.12) · Stage 6 rule overlay (optional).

**Backport / versions:** **21.02.7**, **22.03.7**, **23.05.5** (x86 smoke) + armsr **24.10** — **done**. See [`fwlive-acceptance.md`](fwlive-acceptance.md).

---

## Stage 5 — incremental substeps

| Step | Deliverable | How to accept |
| ---- | ----------- | ------------- |
| **5.0** | Infer `pass` on silent nft `log … accept` lines | `./scripts/fwlive-test.sh`; ping rows show green **pass** in LuCI |
| **5.1** | Click **src** / **dst** → fills filter field | **done** |
| **5.2** | Click **proto**, **interface**, **action** | **done** |
| **5.3** | Filter chip bar (show + clear active filters) | **done** |
| **5.4** | AND multi-field `matchesFilter()` test | **done** — `fwlive-firewall-filter.test.js` |
| **5.5** | URL hash for limit + filter fields | **done** (limit + form fields) |

| **5.6** | `!` prefix operators (is not / not contains) | **done** |

Deferred within stage 5: saved filter templates.

---

## Stage 4b — stream controls (OPNsense parity, planned)

Evaluated and implemented: stream controls (auto-refresh, limit) — see [user guide](user/using-the-ui.md#shared-controls).

| Step | Deliverable | Status |
| ---- | ----------- | ------ |
| **4b.1** | Auto-refresh checkbox ↔ `paused` | **done** |
| **4b.2** | Limit dropdown (25…2000) → `maxHistory` / `visibleRows` | **done** |
| **4b.3** | `localStorage` persistence; default **100** | **done** |
| **4b.4** | Status line shows `shown/limit` while paused/live | **done** |

---

## Stage 4c — session stats (in progress)

| Step | Deliverable | Status |
| ---- | ----------- | ------ |
| **4c.1** | **+N new this session** counter in status | **done** |
| **4c.2** | **buffer full** hint when at limit | **done** |
| **4c.3** | `limit=` in URL hash (shareable view) | **done** |

## Stage 4.5 — flood safety (done)

| Step | Deliverable | Status |
| ---- | ----------- | ------ |
| **4.5.1** | Token bucket (~250 rows/sec render budget) | **done** |
| **4.5.2** | Amber banner + status hint when throttled | **done** |

## Feature backlog (pre-backport)

| Item | Stage | Notes |
| ---- | ----- | ----- |
| UCI / nft **rule name** resolve | 3.4b | **done** — `ubus fwlive rules` |
| Filter **operators** (`!` is not / not contains) | 5.6 | **done** |
| **Show hostnames** checkbox | 6 | **done** — `ubus fwlive resolve`, default off |
| **Server-side firewall read** | 7 | **done** — `ubus fwlive poll` |
| Rule overlay / drawer | 6 | backlog |
| Digest / SSE | 7 | backlog |

---

## Stage 3 — rule attribution (after 5.x)

| Step | Deliverable | How to accept |
| ---- | ----------- | ------------- |
| **3.1** | Parse log `prefix` → `rule_hint` field | **done** — `./scripts/fwlive-test.sh` |
| **3.2** | LuCI **Rule** column | **done** — click hint filters via quick search |
| **3.3** | Deep link to firewall admin | **done** — click Rule filters; Ctrl+click opens admin |
| **3.4a** | `rule_label` display field | **done** — cosmetic label from hint |
| **3.4b** | UCI/fw4 name resolve via `ubus fwlive rules` | **done** |

---

## MVP delivered (committed)

- [x] Modern LuCI JS view (`view.extend`, JSON-RPC `fwlive.poll`)
- [x] Firewall-only feed + normalized schema
- [x] Poll, filters, URL hash, formatted table
- [x] QEMU validation with real `nft log`

---

## Dev loop (daily)

```sh
./scripts/run-openwrt-x86-qemu.sh
./scripts/qemu-install-fwlive.sh
./scripts/fwlive-nft-ping-log.sh add --ssh
ssh -p 2222 root@127.0.0.1 'ping -c 5 127.0.0.1'
./scripts/fwlive-test.sh
./scripts/fwlive-ubus-read.sh --lines 10
```

Production target remains **armsr**; x86 QEMU is the fast UI lab.

---

## References

| Doc | Purpose |
| --- | ------- |
| [Environment setup](developer/environment.md) | Host setup |
| [fwlive-nft-logging.md](fwlive-nft-logging.md) | Enable firewall logs |
| [opnsense-liveview-parity.md](opnsense-liveview-parity.md) | Feature matrix |
| [openwrt-fwlive-schema.md](openwrt-fwlive-schema.md) | Event fields |

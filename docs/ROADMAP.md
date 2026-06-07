# fwview — structured roadmap

Product: **LuCI Firewall Live View** — OPNsense Live View–style operator UX on OpenWrt, client-side JS + `ubus log.read`.

**Architecture:** [fwlive-ui-design-target.md](fwlive-ui-design-target.md) · **Stages:** [fwlive-development-plan.md](fwlive-development-plan.md) · **Acceptance:** [fwlive-acceptance.md](fwlive-acceptance.md)

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
| **MVP** | **Done** | Real nft logs on QEMU x86; stages 1–2; formatting pass |
| **Infra** | **Done** | QEMU x86 lab, `qemu-install-fwlive.sh`, nft ping helper |
| **Stage 4** | **Done (core)** | Pause/resume + buffer status |
| **Stage 5** | **In progress** | Incremental substeps below |
| **Stage 3** Rule attribution | Planned | After stage 5 |
| **Stage 6–7** | Backlog | DNS, digest/SSE |

---

## Post-MVP priority

```
Stage 4 ✓ ──► Stage 5 (small steps) ──► Stage 3 (rules) ──► Stage 6+
```

---

## Stage 5 — incremental substeps

| Step | Deliverable | How to accept |
| ---- | ----------- | ------------- |
| **5.0** | Infer `pass` on silent nft `log … accept` lines | `./scripts/fwlive-test.sh`; ping rows show green **pass** in LuCI |
| **5.1** | Click **src** / **dst** → fills filter field | **done** |
| **5.2** | Click **proto**, **interface**, **action** | **done** |
| **5.3** | Filter chip bar (show + clear active filters) | **done** |
| **5.4** | AND multi-field `matchesFilter()` test | **done** — `fwlive-firewall-filter.test.js` |
| **5.5** | URL hash for tokens (optional) | Reload preserves chips |

Deferred within stage 5: `is not` / `contains` operators, saved templates.

---

## Stage 3 — rule attribution (after 5.x)

| Step | Deliverable | How to accept |
| ---- | ----------- | ------------- |
| **3.1** | Parse log `prefix` → `rule_hint` field | **done** — `./scripts/fwlive-test.sh` |
| **3.2** | LuCI **Rule** column | **done** — click hint filters via quick search |
| **3.3** | Deep link to firewall admin | **done** — click Rule filters; Ctrl+click opens admin |
| **3.4a** | `rule_label` display field | **done** — cosmetic label from hint; UCI resolve backlog |

---

## MVP delivered (committed)

- [x] Modern LuCI JS view (`view.extend`, JSON-RPC `log.read`)
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
| [dev-environment.md](dev-environment.md) | Host setup |
| [fwlive-nft-logging.md](fwlive-nft-logging.md) | Enable firewall logs |
| [opnsense-liveview-parity.md](opnsense-liveview-parity.md) | Feature matrix |
| [openwrt-fwlive-schema.md](openwrt-fwlive-schema.md) | Event fields |

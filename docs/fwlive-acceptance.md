# Firewall Live View Acceptance Criteria

> **Developers:** [Contributing](developer/contributing.md) · [Build & test](developer/build-and-test.md)

## MVP status

**MVP and pre-backport feature work are complete** (stages 1–5 core, 4b, 3.4b, 5.6). Stage 6+ remains backlog — see [Stage 6 (next)](#stage-6--inspect--enrichment-backlog) below.

Re-validate after changes:

```sh
./scripts/fwlive-test.sh
./scripts/validate-baseline.sh          # parser + script gate
./scripts/qemu-smoke-fwlive.sh          # headless guest checks (guest must be running)
# full version loop:
./scripts/validate-openwrt.sh --version 24.10
./scripts/validate-openwrt-all.sh smoke-x86
```

---

## Supported versions and targets

`luci-app-fwlive` builds as **`_all`** (no per-SoC binaries). The app is **not hardware-specific** — LuCI JS, `ubus log.read`, and the ash `rpcd` plugin are portable. **Validating on one ARM target (e.g. armsr/armv8) is sufficient for other ARM boards** on the same OpenWrt version; differences show up by **release** (23.05 vs 24.10), not by CPU model.

| OpenWrt | SDK build | Lab target | End-to-end sign-off |
| ------- | --------- | ---------- | ------------------- |
| **21.02.7** | ✓ x86-64 | **x86_64** (KVM, fw3/iptables) | ✓ `qemu-smoke-fwlive.sh` (2026-06-20) |
| **22.03.7** | ✓ x86-64 | **x86_64** (KVM) | ✓ `qemu-smoke-fwlive.sh` (2026-06-27) |
| **24.10.5** | ✓ armsr-armv8, x86-64 | **armsr/armv8** (production) | ✓ LuCI, ubus, nft log, rules |
| **24.10.5** | ✓ | **x86_64** (fast KVM lab) | ✓ primary dev loop |
| **23.05.5** | ✓ armsr-armv8 | **x86_64** (KVM) | ✓ `qemu-smoke-fwlive.sh` |
| **23.05.5** | ✓ (same `_all` ipk) | armsr/armv8 | Same package; TCG QEMU boot slow — not re-signed in lab |
| **snapshot** | ✓ matrix | — | Best-effort; not formally signed off |

**Production target:** armsr **24.10.5**. **23.05.5** and **22.03.7** supported — see [`openwrt-23.05-compat.md`](openwrt-23.05-compat.md) and [`openwrt-22.03-compat.md`](openwrt-22.03-compat.md).

**iptables LOG (issue #7):** On **21.02.x**, iptables LOG is the **primary** path (lab sign-off on 21.02.7 x86). On **22.03+**, **firewall4/nft** is the supported path; **iptables LOG** is best-effort when iptables is present without nft — fixture-tested. See [`openwrt-21.02-compat.md`](openwrt-21.02-compat.md).

Build:

```sh
./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10
./scripts/docker-sdk.sh build --target x86-64 --version 22.03
./scripts/docker-sdk.sh build --target armsr-armv8 --version 23.05
```

---

## Functional

- Live view refresh interval is approximately one second.
- New firewall log lines appear without page reload.
- Only firewall-shaped `log.read` lines are shown (stage 1).
- Normalized schema: unix `timestamp`, `action` enum, `interface_in`/`out`, `flags`, `length` (stage 2).
- Filters apply immediately for action/interface/protocol/src/dst/ports.
- Quick search matches across all normalized fields.
- URL hash preserves active filters on reload.
- **Auto-refresh** checkbox freezes the table while polling continues; re-check updates the grid (stage 4b).
- **Limit** dropdown (25…2000, default 100) caps buffer and visible rows; persisted in browser (stage 4b).
- **Rule labels** resolve UCI/fw4 names via `ubus fwlive rules` (stage 3.4b); test rule `fwlive-ping` falls back to cosmetic label.
- **Filter operators:** prefix `!` for is-not / not-contains; action dropdown includes **not pass**, **not drop**, etc. (stage 5.6).
- **Flood banner** appears under high ingest rate only (token bucket charges new events per poll, not full row count).
- **Simple view** (default): Action, Time (compact), Interface, Flow, Proto, Rule; no horizontal scroll on typical laptop widths.
- **Detailed view**: 14-column table including Message, Flags, Len, Dir (via **Show Detail** toggle).
- **Detail toggle** persists in `localStorage` after user toggles; `view=detailed` in URL hash restores Detailed mode.
- **Zero-config**: first visit shows live table with auto-refresh; empty state and **Help** are on-router (no build-host doc paths).
- **Simple row expand**: click row shows full netfilter message; second click collapses; filter links do not toggle expand.

---

## Performance

- Parser benchmark target: >= 100k rows/sec on development host.
- Browser render cap: ~250 new events/sec before throttle banner; normal 1 pkt/s must not trigger it.
- History cap: 2000 rows in memory.
- Typical update processing stays under one second poll interval.

---

## Environment

Full loop on **Linux x86_64**: [`dev-environment.md`](dev-environment.md). Enable firewall **`log`**: [`fwlive-nft-logging.md`](fwlive-nft-logging.md).

**QEMU lab (recommended):**

```sh
# 24.10 fast path (x86 KVM)
RELEASE=24.10.5 ./scripts/download-openwrt-x86-64.sh
sudo OWRT_IMG=lab/images/openwrt-x86-64-24.10.5.img ./scripts/qemu-lab-prepare-image.sh
OWRT_RELEASE=24.10.5 ./scripts/run-openwrt-x86-qemu.sh

# Production-shaped (armsr, TCG — allow slow boot)
RELEASE=24.10.5 ./scripts/download-openwrt-armsr-armv8.sh
sudo OWRT_IMG=lab/images/openwrt-armsr-armv8.img ./scripts/qemu-lab-prepare-image.sh
./scripts/run-openwrt-armsr-armv8-qemu.sh
```

---

## Validation commands (no browser)

```sh
./scripts/fwlive-test.sh
node core/fwlive-log.js stats < tests/fixtures/logread-mixed.json
node core/fwlive-log.js filter < tests/fixtures/logread-mixed.json
./scripts/fwlive-ubus-read.sh --stats    # live guest over SSH
./scripts/fwlive-rules-ubus.sh           # rule hint → label map (stage 3.4b)
./scripts/qemu-smoke-fwlive.sh           # SSH + ubus + LuCI static + optional ping log
```

---

## LuCI smoke (feature completion)

```sh
./scripts/qemu-install-fwlive.sh
./scripts/fwlive-nft-ping-log.sh add --ssh
ssh -p 2222 root@127.0.0.1 'ping 127.0.0.1'   # 1 pkt/s baseline
# http://localhost:8080/cgi-bin/luci/admin/status/fwlive
```

| Check | Pass |
| ----- | ---- |
| Rule column shows **fwlive ping** (or UCI name when resolvable) | ✓ |
| Action **not pass** hides green pass rows | ✓ |
| Src **!127.0.0.1** excludes loopback pings | ✓ |
| Limit 250 + 1 pkt/s: **no** flood banner | ✓ |
| `ping -A 127.0.0.1`: flood banner appears, UI stays responsive | ✓ |
| Uncheck auto-refresh: ingest count rises ~1/s | ✓ |
| Headless smoke (`qemu-smoke-fwlive.sh`) on 23.05.5 x86 | ✓ |
| armsr 24.10.5 LuCI page loads in browser | ✓ |

Validated on **QEMU x86_64 21.02.7**, **22.03.7**, **24.10** (KVM) and **armsr 24.10.5** (TCG); **23.05.5** via x86 smoke + same `_all` ipk.

---

## Stage 6 — Inspect & enrichment (partial)

| Item | Status |
|------|--------|
| **Show hostnames** toolbar checkbox (default off) | **done** — `ubus fwlive resolve`, IP in tooltip when resolved |
| Rule overlay | backlog |
| Row detail drawer | backlog |

## Stage 7 — Transport (partial)

| Item | Status |
|------|--------|
| **`ubus fwlive poll`** — server-side firewall-only filter | **done** |
| Digest + incremental fetch, SSE | backlog |

---

Stage plan: [ROADMAP.md](ROADMAP.md).

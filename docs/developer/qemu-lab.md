# QEMU lab

Headless OpenWrt guests for install and smoke testing without hardware.

## Images

Downloaded to `lab/images/`:

```sh
RELEASE=24.10.8 ./scripts/download-openwrt-x86-64.sh
RELEASE=23.05.5 ./scripts/download-openwrt-x86-64.sh
RELEASE=22.03.7 ./scripts/download-openwrt-x86-64.sh
RELEASE=21.02.7 ./scripts/download-openwrt-x86-64.sh
RELEASE=24.10.8 ./scripts/download-openwrt-armsr-armv8.sh
```

## Prepare image (required once per image)

Sets LAN **dhcp** for slirp, relaxes lab firewall, empty root password, dropbear auth, uhttpd/LuCI fixes. **22.03.x** fresh x86 images may lack `/etc/config/network` — the script seeds DHCP `lan` before first boot (see [22.03 notes](../supported-releases.md#2203x-eol)):

```sh
sudo OWRT_IMG=lab/images/openwrt-x86-64-24.10.8.img ./scripts/qemu-lab-prepare-image.sh
```

Always pass **`OWRT_IMG`** to the versioned file — the script default is the armsr image.

## Run

**x86 (KVM, fast):**

```sh
OWRT_RELEASE=24.10.8 ./scripts/run-openwrt-x86-qemu.sh
# stop: ./scripts/run-openwrt-x86-qemu.sh --stop
```

**armsr (TCG, slow):**

```sh
OWRT_RELEASE=24.10.8 ./scripts/run-openwrt-armsr-armv8-qemu.sh
```

Ports (default): LuCI **8080**, SSH **2222**.

Reset OVMF vars if GRUB hangs between matrix runs:

```sh
cp /usr/share/OVMF/OVMF_VARS_4M.fd lab/images/OVMF_VARS_4M.fd
```

## Install package on guest

```sh
./scripts/qemu-wait-guest.sh
OWRT_FWLIVE_VERSION=24.10.8 ./scripts/qemu-install-fwlive.sh
```

Uses `apk` or `opkg` based on package extension and guest userspace.

## Generate test traffic

```sh
./scripts/fwlive-nft-ping-log.sh add --ssh
ssh -p 2222 root@127.0.0.1 'ping -c 5 127.0.0.1'
./scripts/fwlive-ubus-read.sh --lines 20
```

Reset WAN logging state before toggle/uninstall tests (QEMU disk persists UCI):

```sh
./scripts/qemu-reset-wan-logging.sh
./scripts/qemu-logging-uninstall-smoke.sh
```

## Poll hot-path profiling (#308)

Investigation-first tooling for the per-poll shell cost plan. **Phase 0a** (host)
lands the census harness and baseline numbers; **Phase 0b** ([#310](https://github.com/lucas-albers-lz4/fwlive/issues/310))
fills the device budget-split table on armsr. Do not prioritize S1–S10 candidates
from host numbers alone.

### Methodology

```sh
# Exec census (PATH-shim external commands only; builtin-only subshell forks
# are outside this count — see scripts/fork-census.sh header)
./scripts/fork-census.sh
./scripts/fork-census.sh --fixture tests/fixtures/logread-2000.json

# Parse-only medians (host convention: median of 50)
# Device convention (Phase 0b): wall-ms median of 5 per stage
```

- **Host stats:** median-of-50 for `bash -n` parse timings; exec totals from the census.
- **Device stats (0b):** wall-ms median-of-5; timing primitive must be
  `busybox date +%s%3N` or `/proc/uptime` centiseconds — **not** `date +%s`.
- Label every table with **substrate** (e.g. `host/x86_64/bash`, `qemu-armsr-tcg`).
- Regenerate the flood fixture: `./scripts/gen-logread-fixture.sh` →
  `tests/fixtures/logread-2000.json` (2000 entries).

### Historical host baseline (Phase 0a, pre-#321/#308 — non-authoritative)

> **Non-authoritative — host exec census via `/bin/sh` (Dash on this host), parse timings via Bash. Do not use for candidate prioritization.**

Measured 2026-09-08 on `x86_64` Linux host at `f1399c2` (pre-PR tip of master);
fixture `tests/fixtures/logread-mixed.json` (7 entries / 919 bytes). The parse
timings below are historical reference values from that measurement and should
not be treated as current performance claims. Shim list includes `dirname`
(#308 Phase 0a). The current census also exercises rpcd's production stdin
request path, adding the `read_rpc_input` stdin capture to the poll total.

| stage | exec count | parse-ms median-of-50 | notes |
|-------|------------|----------------------|-------|
| rpcd entrypoint (`bash -n`) | — | 2.0 | Does **not** follow `.` sources |
| `fwlive-logging.sh` (`bash -n`) | — | 2.0 | Sourced by rpcd every exec |
| rpcd+logging (sum of medians) | — | 4.0 | Host proxy for poll-process parse |
| filter parse (`bash -n`) | — | 1.0 | `fwlive-log-filter.sh` alone |
| classify parse (`bash -n`) | — | 1.0 | Generated heredoc shell wrapper |
| filter subprocess | 5 | — | dirname + stdin cat + jsonfilter + heredoc cat + awk |
| full poll (`rpcd call poll`) | 8 | — | dirname (rpcd) + stdin cat + ubus + filter 5; jshn/sed not on host |

Re-run: `./scripts/fork-census.sh` (prints `CENSUS_FILTER_TOTAL` /
`CENSUS_POLL_TOTAL`). This pre-optimization record measured filter=5 and
poll=8; the current gate records the post-#321/#308 values below.

### Post-#321/#308 host census

Measured 2026-09-15 on the same host and `logread-mixed.json` fixture after
extracting the classifier asset and streaming filter stdin. The filter is now
**5** execs (`dirname`, `jsonfilter`, `mktemp`, `awk`, `rm`), with jsonfilter
output staged in a mode-0600 temporary file before classification. This avoids
partial JSON output when jsonfilter fails, including on shells without
pipefail. The full production-shaped poll is **8** on this host (`dirname`×2,
stdin `cat`, `ubus`, and the 5-exec filter chain). The census records these as
`CENSUS_FILTER_TOTAL=5` and `CENSUS_POLL_TOTAL=8`.

### Device budget-split table (Phase 0b — armsr TCG)

Tracked in [#310](https://github.com/lucas-albers-lz4/fwlive/issues/310). The
following run used OpenWrt 24.10.8 (`r29233-443ec4032a`), `aarch64`, BusyBox
ash, one vCPU, 256 MiB, QEMU TCG on the Linux x86_64 host, and source SHA
`4ac992d`. The guest's `busybox date` ignored `%N`; `/proc/uptime` provided a
10 ms clock. Each row below reports all five raw samples in milliseconds,
followed by median ± full spread. Batched rows retain their repeat count in the
raw values; values below the clock resolution are not represented as zero.

| stage | exec count | raw samples (ms, n=5) | median ± spread (ms) | share of full poll (median 950 ms) |
|-------|------------|------------------------|----------------------|------------------------------------|
| rpcd parse (`sh -n`, n=20) | n/a (shell startup) | 32, 31, 31, 43, 32 | 32 ± 12 | 3.4% |
| jshn (n=20) | 1 | 21, 21, 21, 21, 21 | 21 ± 0 | 2.2% |
| log.read + capture (n=5) | 1 (`ubus`) | 68, 60, 58, 60, 58 | 60 ± 10 | 6.3% |
| filter parse (`sh -n`, n=20) | n/a (shell startup) | 18, 17, 17, 18, 17 | 17 ± 1 | 1.8% |
| `read_rpc_input` stdin capture (source + stdin, n=20) | 1 (`cat`) | 99, 97, 98, 95, 100 | 98 ± 5 | 10.3% |
| filter stdin cat (n=10) | 1 | 18, 20, 18, 20, 17 | 18 ± 3 | 1.9% |
| jsonfilter (n=5) | 1 | 170, 152, 150, 152, 152 | 152 ± 20 | 16.0% |
| heredoc cat (n=50) | 1 | 15, 15, 15, 15, 16 | 15 ± 1 | 1.6% |
| awk classify (n=5) | 1 | 110, 104, 104, 104, 112 | 104 ± 8 | 10.9% |
| stdout → blobmsg | n/a | unresolved in shell attribution | n/a | n/a |
| HTTP + JS parse | n/a | not part of device poll | n/a | n/a |
| JS render | n/a | not part of device poll | n/a | n/a |

The full real-logd `ubus call fwlive poll` samples were 980, 940, 950, 950,
940 ms (median 950 ± 40 ms). The 205,475-byte/2,000-entry fixture filter is a
separate microbenchmark: 15,630, 15,330, 15,660, 14,770, 14,540 ms (median
15,330 ± 1,120 ms), and must not be substituted for real logd capture. A
PATH-shim fixture poll observed 10 external execs: `dirname`×2, `cat`×3
(including the production stdin capture), `jshn`×1, `sed`×1, `ubus`×1,
`jsonfilter`×1, and `awk`×1. The stage shares are inclusive and overlap; they
are not expected to sum to 100%.

For the repeatable run and raw output, use:

```sh
OPENWRT_SSH_PORT=2222 ./scripts/qemu-budget-split.sh
```

The same harness on an x86_64 24.10.5 guest with two vCPUs/256 MiB and KVM
measured the fixture filter at 750–780 ms (median 770 ms) and a real poll at
20–30 ms (median 30 ms). This is a host-side comparison only; it does not
replace the armsr TCG table or predict native ARM timings.

### Post-#321/#308 device rerun

Measured 2026-09-11 after both hot-path changes on OpenWrt 24.10.8
(`r29233-443ec4032a`), `aarch64`, BusyBox ash 1.36.1-r3, one vCPU, 256 MiB,
QEMU TCG, source SHA `e3614d528d` (the `perf/310-device-budget` head carrying
the `awk -f` asset and the regenerated `id` fixture — every stage row below
exists only from this tree), and `/proc/uptime` 10 ms
resolution. The guest system log buffer was `log_size=128` KiB
(`system.@system[0].log_size`; there is no separate `log_buffer_size` UCI key).
The regenerated fixture was 224,365 bytes / 2,000 entries and includes a
monotonic `id` field per entry.

| stage | exec count | raw samples (ms, n=5) | median ± spread (ms) | share of full poll (median 810 ms) |
|-------|------------|----------------------|----------------------|------------------------------------|
| rpcd parse (`sh -n`, n=20) | n/a (shell startup) | 31, 31, 33, 31, 31 | 31 ± 2 | 3.8% |
| jshn (n=20) | 1 | 22, 22, 21, 22, 21 | 22 ± 1 | 2.7% |
| log.read + capture (n=5) | 1 (`ubus`) | 68, 66, 64, 66, 66 | 66 ± 4 | 8.1% |
| filter parse (`sh -n`, n=20) | n/a (shell startup) | 18, 17, 16, 17, 17 | 17 ± 2 | 2.1% |
| `read_rpc_input` stdin capture (source + stdin, n=20) | 1 (`cat`) | 95, 96, 97, 98, 101 | 97 ± 6 | 12.0% |
| jsonfilter (n=5) | 1 | 176, 172, 178, 180, 178 | 178 ± 8 | 22.0% |
| classifier file (`awk -f`, n=5) | 1 | 46, 42, 46, 42, 44 | 44 ± 4 | 5.4% |
| awk classify (n=5) | 1 | 80, 80, 82, 82, 78 | 80 ± 4 | 9.9% |
| stdout → blobmsg | n/a | unresolved in shell attribution | n/a | n/a |

Full real-logd `ubus call fwlive poll` samples were 800, 840, 810, 820, 810
ms (median **810 ± 40 ms**). The fixture filter samples were 15,010, 15,180,
15,460, 15,210, 15,350 ms (median **15,210 ± 450 ms**), kept separate from
real poll latency. A PATH-shim fixture poll observed **8** external execs:
`dirname`×2, `cat`×1 (the rpcd request capture), `jshn`×1, `sed`×1,
`ubus`×1, `jsonfilter`×1, and `awk`×1. The former heredoc `cat` row is gone;
the `classifier file` row measures the replacement `awk -f` invocation, not a
standalone file-open cost. Stage shares remain inclusive and non-additive.

**0b checklist**

- [x] Timing primitive probe on guest (`/proc/uptime`, 10 ms resolution; `%N` unsupported)
- [x] Install fwlive on armsr guest
- [x] Stage attribution on `tests/fixtures/logread-2000.json` (five raw samples, median and spread)
- [x] Record substrate (`qemu-armsr-tcg`) + date + git SHA

## Memory profiling (#319)

Harness: [`scripts/memory-census.sh`](../../scripts/memory-census.sh). Manual/release
profiling only — no CI guest job yet (same stance as the #310 device table).

### Metric contract

- **Budget series = summed VmRSS (kB)** of the chosen process tree. Soft ceilings
  bind on RSS, not PSS. The harness **probes** `/proc/*/smaps_rollup` each run:
  when PSS is available it emits `PROFILE_META primitive=pss` and companion
  `pss_kb` samples; otherwise `primitive=vmrss` and no PSS rows. Do not assume
  PSS by architecture — record the probe result from the guest run.
- **Idle ≠ peak.** Idle is rpcd-at-rest (+ leaked descendants). Peak is the max
  of concurrent ~50 ms tree samples during one poll (BusyBox `sleep` may be 1 s
  only — the harness busy-waits on `/proc/uptime` centiseconds). Sampled peak is
  not `/proc` `VmPeak` (virtual); worker `VmHWM` is an optional companion.
- **Split roots.** C1 (PATH-shim direct `/usr/libexec/rpcd/fwlive call poll`,
  fixture-backed `log read`) uses `root=fwlive`. C2 / idle / retention
  (`ubus call fwlive poll`) use `root=rpcd`. Never walk rpcd for C1.
- **C1 exercises the full poll path** (`raw=$(ubus…)` + filter), not filter-only.
- **RSS sums double-count** shared text across ash/jsonfilter/awk children —
  intentional; document it; use PSS to quantify when the probe finds it.
- **Sub-50 ms children** (jshn/dirname/cat) may be missed by the sampler;
  jsonfilter/awk usually appear.
- **Case order and settles:** idle → **nofork** (60 s zero-poll baseline, **no**
  10 s settle) → C2 (n=5) → **10 s settle** → retention T0 → 10× C2 polls →
  60 s idle → T1 (`Δ = T1 − T0`; `delta_rss_kb=invalid` if any retention poll
  fails) → C1 last. Soft-budget **Z is sized from the nofork Δ only**. A peak
  sample with no in-flight tree observation is `value=invalid`, not a post-exit
  walk.
- **logd** RSS is a context metric only — never added to the fwlive budget sum.
- **Line pins:** C2 `addresses:["50"]` = normal; C1 fixture / `["2000"]` = max.
  Record returned `lines=` (stock 64 KiB ring may not hold 2000).
- Emit `n=5` peak samples per poll case (same convention as #310). Join CPU and
  memory rows with `PROFILE_META run_id=…` (`FWLIVE_PROFILE_RUN_ID` or auto).

### Soft budget (committed 2026-09-12)

| Ceiling | Value | Notes |
|---|---|---|
| Idle RSS (X) | ≤ 8 MB | ~5–10% of the 128 MB device class |
| Peak process-tree RSS (Y) | ≤ 16 MB | ≈ 2× idle; fork-heavy poll |
| Retained Δ RSS (Z) | ≤ **1 MB** | From first nofork baselines (both substrates Δ = 0 KB); 1 MB is the noise-floor soft ceiling so AC-4 stays usable |
| Future stretch | 64 MB class | Documented only; not binding |

- **Binding substrate:** x86_64 guest targeting the **128 MB device class**. Lab EFI
  combined images fail kernel decompress at `OWRT_QEMU_MEM=128`; use
  **`OWRT_QEMU_MEM=160`** (guest `MemTotal` ≈ 128 MiB after OVMF). Hardcoded
  `-smp 2` is fine.
- **Production-target confirmation:** armsr `OWRT_QEMU_SMP=1 OWRT_QEMU_MEM=256`.
- **Owner:** @lucas-albers-lz4. Re-evaluate each release; re-open automation if a
  single change regresses peak RSS by >10% or retained RSS by > Z.

### Actionable rule (AC-4)

Compare a candidate’s **post** C1 (or C2) peak series to the **pre-change**
baseline of the same case. Units are kB (VmRSS process-tree peak).

Definitions (from the five `peak_rss_kb` samples for that case):

- `baseline_peak` / `post_peak` — median of the five samples (kB)
- `baseline_mean` — arithmetic mean of the five baseline samples (kB)
- `σ` — sample standard deviation of those five baseline samples (kB)
- `Δ_peak` — `post_peak − baseline_peak` (kB); actionable thresholds apply to
  this **increase**, not to the absolute post value alone

A memory change is actionable if **any** of:

1. `Δ_peak > 2σ`, or
2. `Δ_peak > 0.05 × baseline_peak`, or
3. `Δ_peak > 8192` (8 MB absolute)

Disposition before merge: owner approval, blocking follow-up issue, or
documented exception here.
### #308 gate linkage (AC-6)

Any #308 S-candidate PR that changes fork/exec count or pipeline structure must
include pre/post peak and retained RSS snapshots (from this harness) in the PR
description.

### First calibration (2026-09-12)

Package `luci-app-fwlive` 0.1.40-r1 + feed sync from harness tip `c56085a`.
Fixture `tests/fixtures/logread-2000.json` (224,365 bytes). Primitive on both
guests: **VmRSS only** (`/proc/self/smaps_rollup` absent on released 24.10.8
x86_64 and armsr images — companion PSS not available for this calibration).

#### Binding — x86_64 KVM (`OWRT_QEMU_MEM=160` → MemTotal 128 MiB, smp=2)

`run_id=z-x86-20260912T091043`. OpenWrt 24.10.8 (`r29233-443ec4032a`), BusyBox
1.36.1-r3.

| Case | Metric | Values (kB) | Notes |
|---|---|---|---|
| idle | rss | 1788 | nprocs=1; under X |
| idle | logd_rss | 936 | context only |
| nofork | delta_rss | **0** | Z sized from this |
| c2_live | peak_rss (n=5) | 1792, 1800, 1800, 1796, 1800 | median **1800**; lines=0 (empty ring); nprocs=1 |
| retention | delta_rss | 4 | after 10× C2 + 60 s |
| c1_fixture | peak_rss (n=5) | 8768, 8844, 8808, 8808, 8816 | median **8808** (~8.6 MB); lines=1143; nprocs=6; under Y |

#### Confirmation — armsr TCG (`OWRT_QEMU_SMP=1 OWRT_QEMU_MEM=256`)

`run_id=z-armsr-20260912T091441`. Same release/BusyBox. MemTotal 233 MiB.

| Case | Metric | Values (kB) | Notes |
|---|---|---|---|
| idle | rss | 2344 | under X |
| idle | logd_rss | 992 | context only |
| nofork | delta_rss | **0** | confirms Z floor |
| c2_live | peak_rss (n=5) | 2352 × 5 | median **2352**; lines=0; nprocs=1 |
| retention | delta_rss | 4 | same shape as x86 |
| c1_fixture | peak_rss (n=5) | 5948, 9396, 9384, 9448, 9224 | median **9384** (~9.2 MB); lines=1143; under Y |

Both substrates satisfy X/Y/Z. C2 peaks ≈ idle because the stock ring had no
firewall lines (`lines=0`); C1 fixture is the authoritative max-poll peak for
this calibration.

### Checklist

- [x] Harness + this stub
- [x] Guest primitive probe confirm (both substrates: VmRSS only on 24.10.8 images)
- [x] Idle / nofork / retention baselines + C2/C1 peak samples (n=5 peaks)
- [x] Commit numeric Z from nofork; fill result tables
- [x] armsr confirmation run against soft budget
- [x] Degraded-mode adaptive-cap baseline — harness: [`scripts/qemu-adaptive-flood.sh`](../../scripts/qemu-adaptive-flood.sh); binding armsr C1 table filled (`ac_pass=1`, run `flood-armsr-20260912T174001`)
- [ ] Degraded-mode visibility-pause baseline — Layer 2 client backoff landed (`feat/306-layer2-visibility-backoff`); host unit coverage in `tests/fwlive-view-layer2-backoff.test.js`; Playwright/CDP gate is tracked in [#339](https://github.com/lucas-albers-lz4/fwlive/issues/339)

### Adaptive flood evidence (#306 Layer 1)

Harness (host → guest SSH):

```bash
OWRT_RELEASE=24.10.8 OWRT_QEMU_SMP=1 OWRT_QEMU_MEM=256 \
  ./scripts/run-openwrt-armsr-armv8-qemu.sh
./scripts/qemu-wait-guest.sh
OWRT_FWLIVE_VERSION=24.10.8 OWRT_FWLIVE_ARCH=aarch64_generic \
  ./scripts/qemu-install-fwlive.sh
set -o pipefail
FWLIVE_PROFILE_RUN_ID="flood-armsr-$(date +%Y%m%dT%H%M%S)" \
  OPENWRT_SSH_PORT=2222 ./scripts/qemu-adaptive-flood.sh | tee lab/flood-armsr-latest.txt
```

`qemu-install-fwlive.sh` syncs `fwlive-adaptive-cap.sh` with the other libexec helpers.

#### Binding table — armsr TCG PATH-shim C1

Measurement path is **fixture PATH-shim** (same class as memory-census C1), not
stock-ring logd. Induce uses the 2000-entry fixture filter (~37 s on armsr TCG);
follow polls honor `lines=` via the shim so delivered msgs ≤250.

Run: `flood-armsr-20260912T174001` · git `a4d0b2f` · 2026-09-12 · BusyBox 1.36.1-r3

| field | value |
|-------|-------|
| substrate | `qemu-armsr-tcg` / path=`c1_fixture_shim` |
| SMP / MEM | `1` / `256` (guest `nproc=1`, `memtotal_kb=238556`) |
| OpenWrt | 24.10.8 `r29233-443ec4032a` |
| log UCI | skipped for C1 (`--raise-log` optional) |
| induce (on) | `state_bucket=hot`, `state_duration_ms=36630`, wall 37030 ms, 1143 msgs |
| resolve (on) | `disabled=load` immediately after induce |
| follow×3 (on) | `truncated:1`, `shed.limit=250`, **143** msgs each; wall ~5410–5640 ms |
| A/B (off) | `adaptive:0`, no shed; **1143** msgs; follow wall ~36100–36670 ms |
| `FLOOD_VERDICT ac_pass` | **1** (`on_induce_hot` ∧ `on_follow` ∧ `on_resolve` ∧ `off_follow`) |

**Interpretation (Grok):** outcome row “on sheds ≤250; off stays large / slower” → next #306 slice is **Layer 2** (client surfacing + backoff), not threshold calibration and not fork-budget-first. Caveat: follow stays hot (~5 s > 800 ms) so cooldown / upward re-probe is not demonstrated on this substrate.

#### Raised-ring real-logd validation

A real-logd run on the same canonical armsr rig was completed on 2026-09-15
with `system.@system[0].log_size=1024` KiB (not the fixture PATH shim). The
guest was OpenWrt 24.10.8 `r29233-443ec4032a`, 1 vCPU / 256 MiB, and the
workload injected 2,000 firewall-shaped messages through `/dev/log`.

| poll | `messages_received` | classified rows | truncated | `shed.limit` | state duration / bucket |
|------|---------------------|------------------|-----------|--------------|-------------------------|
| initial full | 2,000 | 2,000 | 0 | — | 24,020 ms / hot |
| follow 1 (expired cooldown probe) | 500 | 488 | 1 | 500 | 5,840 ms / hot |
| follow 2 | 250 | 238 | 1 | 250 | 3,330 ms / hot |
| follow 3 | 250 | 238 | 1 | 250 | 3,290 ms / hot |
| recovery probe after logd restart | 8 | 8 | 1 | — | 380 ms / warm |
| recovery upward probe after warm cooldown | 11 | 8 | 1 | — | 380 ms / warm, retained limit 1,000 |

This demonstrates the real-logd raised-ring path, an upward probe after the
hot cooldown, and return to the 250-line floor when the probe remains hot. A
small-ring recovery run exited hot state at 380 ms without a shed field and
then raised the retained warm limit from 500 to 1,000 after the warm cooldown.
It did not return to a cold/full 2,000-line cap, and it is not forwarding-SLO
evidence; those remain separate #306 acceptance items.

The visibility-pause degraded baseline is still pending the Playwright/CDP timing measurement.

The repeatable browser gate uses the real LuCI page with only `fwlive.poll`
replaced by the checked-in 2,000-entry fixture:

```sh
FWLIVE_URL=http://127.0.0.1:8080 \
FWLIVE_CPU_THROTTLE=4 \
FWLIVE_SOAK_MS=1800000 \
./scripts/qemu-layer2-performance.sh
```

It reports visibility pause/resume, render-commit-to-paint samples, largest
`longtask`, and Chromium heap growth. A short `FWLIVE_SOAK_MS` is for harness
development only; #306 sign-off requires the 30-minute run.

On 2026-09-15, the development gate was rerun after the table renderer gained
keyed row reuse and targeted insertion for unchanged poll rows. With the same
4x CPU throttle, 2,000-entry fixture, 1,143 visible rows, and 6-second soak,
it observed 15 polls, 15 table mutations, 188.4 ms render-commit-to-paint p95,
774.7 ms maximum paint delay, and a 943 ms largest main-thread task. Heap
growth was -1.16 MiB at the final forced-GC sample, with a +2.84 MiB sampled
peak. The result is effectively flat against the earlier ~949 ms largest task:
the renderer now avoids rebuilding unchanged cells, but this workload remains
dominated by table layout/paint. This is development evidence, not #306 sign-
off evidence.

The documented 30-minute run completed on the same rig on 2026-09-15: 1,809
polls and table mutations, 172.7 ms render-commit-to-paint p95, 863.6 ms
maximum paint delay, and a 1,056 ms largest main-thread task. It recorded 1,807
long tasks at or above 250 ms. Final forced-GC heap growth was -0.28 MiB, with
a +10.83 MiB sampled peak, and the client stayed out of summary mode. This
confirms no sustained heap growth in the fixture run, but it does not meet a
responsiveness SLO; the workload remains layout/paint-bound.

To exercise the Layer 2 first-slow-RTT summary transition without waiting on a
slow guest, add `FWLIVE_PERF_POLL_DELAY_MS=1600`. This is a harness-only delay;
it does not model the server's adaptive-cap processing duration.

For the #339 display-limit comparison, the harness accepts the full shipped
Limit range: `25`, `50`, `100`, `250`, `500`, `1000`, and `2000`. Fixture mode
defaults to the maximum `2000`-row selection; the shipped default remains the
100-row option. An explicit `FWLIVE_PERF_ROW_LIMIT` also applies to real-poll
mode. If it is unset in real-poll mode, the harness observes the guest's
current UI preference (or its default), for example:

```sh
FWLIVE_PERF_ROW_LIMIT=500 FWLIVE_CPU_THROTTLE=4 FWLIVE_SOAK_MS=10000 \
./scripts/qemu-layer2-performance.sh
```

The report records `display_row_limit` and `visible_rows`. Compare the largest
main-thread task and render-commit-to-paint distribution at the same CPU
throttle and soak duration. The harness does not change the selectable Limit
options or the configured buffer size. The production view now separately caps
DOM rendering at 250 rows when `logging_status.weak_device` is the strict
boolean `true`; the cap is reported in the status line and does not discard
buffered rows.

As a dated example run (2026-09-15), the comparison used the shipped 100-row
baseline plus 250, 500, 1000, and 2000 selected rows. On Chromium 148 /
x86_64 KVM at 4x throttle it found that 250 visible rows stayed below the
250 ms render/task target, while 500 rows crossed it. A 30-second 250-row
confirmation measured 50.9 ms p95 paint, 175.7 ms maximum paint, a 217 ms
largest task, and zero long tasks at or above 250 ms. With
`FWLIVE_PERF_WEAK_DEVICE=1`, a 2,000-row selected Limit was clamped to 250
rendered rows and measured 50.0 ms p95 / 182.4 ms maximum paint, 223 ms
largest task, and zero long tasks at or above 250 ms. These numbers are
environment-specific example evidence; repeat the method above for current
hardware/browser results. The weak-device toggle controls the synthetic
`logging_status` response in fixture mode; production receives the boolean
from the real `logging_status` response.

For a supplemental loaded-router check, leave the poll path real and run this
mode while a guest load/traffic producer is active:

```sh
FWLIVE_PERF_REAL_POLL=1 \
FWLIVE_SOAK_MS=120000 \
./scripts/qemu-layer2-performance.sh
```

This mode reports actual ubus poll RTTs and validates client cadence/backoff;
it is separate from the controlled 2,000-entry browser-rendering gate.

### Forwarding-SLO topology (#306 / #344)

The forwarding SLO requires two traffic endpoints routed through the guest.
The management slirp NIC and a viewer Pause state are not valid forwarding
baselines. The host-side topology helper creates one endpoint namespace and
one bridge/TAP pair on each side of the armsr guest; all resources use the
`fwlive-slo-` prefix and are removed by the matching teardown command:

```sh
sudo ./scripts/qemu-forwarding-slo-net.sh setup
./scripts/qemu-forwarding-slo-net.sh qemu-args
sudo ./scripts/qemu-forwarding-slo-net.sh status
sudo ./scripts/qemu-forwarding-slo-net.sh teardown
```

The printed TAP arguments are an addition to the QEMU management NIC, not a
replacement for it. The guest must be configured with `192.0.2.1/24` on the
LAN TAP-backed interface and `198.51.100.1/24` on the WAN TAP-backed
interface, with IPv4 forwarding enabled; the namespaces use `.2` on each
side and install host routes through the guest. The helper does not configure
the guest, launch QEMU, or run traffic, so an incomplete topology cannot be
mistaken for SLO evidence. The measurement harness will add the required
`iperf3`/ping preflight, no-viewer versus active-viewer drain check, adaptive
on/off split, and five-pair report in #344.

Install `iperf3` in the armsr guest with its signed release feed when preparing
the image (the router is useful for the package/tool preflight, but is not one
of the two forwarded traffic endpoints):

```sh
ssh -p 2222 root@127.0.0.1 'opkg update && opkg install iperf3'
```

After adding the TAP arguments to the QEMU command, configure the guest links
by MAC and install temporary forwarding/logging rules in the existing firewall.
The two directional rules log up to 25 messages per second with the fixed
`fwlive-slo ` prefix and accept every packet; logging is therefore identical
for the no-viewer and active-viewer halves of every pair while the test avoids
turning an unrestricted packet log into a logger-only benchmark:

```sh
./scripts/qemu-forwarding-slo-guest.sh configure
./scripts/qemu-forwarding-slo-guest.sh check
./scripts/qemu-forwarding-slo-guest.sh cleanup
```

The guest helper only touches the two MAC-selected TAP interfaces, its two
temporary `fwlive-slo-*` forwarding rules, and the IPv4-forwarding sysctl.

Once both helpers report ready, one traffic sample can be collected with the
same endpoint namespaces on every run:

```sh
sudo FWLIVE_SLO_IPERF_DURATION=10 FWLIVE_SLO_PING_COUNT=20 \
  ./scripts/qemu-forwarding-slo-traffic.sh --label no-viewer
```

The sample command reports raw receive throughput and ping RTT standard
deviation only. It does not decide whether the SLO passes. Run the paired
orchestrator separately for adaptive on and off; it keeps the guest boot and
forwarding rules fixed, drains between samples, and records every viewer
request/cadence plus the matching traffic metrics:

```sh
FWLIVE_SLO_REPORT_FILE=/tmp/fwlive-slo-adaptive-on.json \
  ./scripts/qemu-forwarding-slo-run.sh --adaptive on
FWLIVE_SLO_REPORT_FILE=/tmp/fwlive-slo-adaptive-off.json \
  ./scripts/qemu-forwarding-slo-run.sh --adaptive off
```

The default is five 10-second pairs with 20 pings per sample. The report
contains all samples, pair deltas, median/spread, request drain results, and
an optional `--enforce` decision for the `<10%` throughput and `<2x` ping
standard-deviation criteria. A run is evidence only when all pairs complete;
the short one-pair/short-duration settings are for harness smoke testing.

### Sample invocation (memory census)

```sh
# Binding: x86_64 128 MB class (lab: MEM=160 → guest MemTotal ≈ 128 MiB)
OWRT_RELEASE=24.10.8 OWRT_QEMU_MEM=160 ./scripts/run-openwrt-x86-qemu.sh
# wait + install fwlive, then:
OPENWRT_SSH_PORT=2222 ./scripts/memory-census.sh

# Confirmation: armsr weak-device rig
OWRT_RELEASE=24.10.8 OWRT_QEMU_SMP=1 OWRT_QEMU_MEM=256 ./scripts/run-openwrt-armsr-armv8-qemu.sh
OPENWRT_SSH_PORT=2222 ./scripts/memory-census.sh
```

## Further reading

- [`../armvirt-armsr-testing.md`](../armvirt-armsr-testing.md)
- [`../openwrt-rootfs-x86-docker.md`](../openwrt-rootfs-x86-docker.md) — optional Docker experiment
- [`../../lab/README.md`](../../lab/README.md)
- [#319](https://github.com/lucas-albers-lz4/fwlive/issues/319) — memory footprint requirements

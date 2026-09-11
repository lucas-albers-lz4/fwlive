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

### Historical host baseline (Phase 0a — non-authoritative)

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
`CENSUS_POLL_TOTAL`). CI asserts filter=5 and poll=8 via `fwlive-test.sh`.

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

**0b checklist**

- [x] Timing primitive probe on guest (`/proc/uptime`, 10 ms resolution; `%N` unsupported)
- [x] Install fwlive on armsr guest
- [x] Stage attribution on `tests/fixtures/logread-2000.json` (five raw samples, median and spread)
- [x] Record substrate (`qemu-armsr-tcg`) + date + git SHA

## Further reading

- [`../armvirt-armsr-testing.md`](../armvirt-armsr-testing.md)
- [`../openwrt-rootfs-x86-docker.md`](../openwrt-rootfs-x86-docker.md) — optional Docker experiment
- [`../../lab/README.md`](../../lab/README.md)

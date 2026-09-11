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

### Device budget-split table (Phase 0b — placeholder)

Tracked in [#310](https://github.com/lucas-albers-lz4/fwlive/issues/310). Fill after
armsr guest install; replace this placeholder. Schema from #308 R1:

| stage | exec count | wall-ms median-of-5 | % of poll total |
|-------|------------|---------------------|-----------------|
| rpcd parse | | | |
| jshn | | | |
| log.read + capture | | | |
| filter parse | | | |
| cat capture (filter stdin) | | | |
| jsonfilter | | | |
| heredoc + cat (classify) | | | |
| awk classify | | | |
| stdout → blobmsg | | | |
| HTTP + JS parse | | | |
| JS render | | | |
| `read_rpc_input` stdin-cat | | | production expect 1 |

**0b checklist**

- [ ] Timing primitive probe on guest (`%3N` or `/proc/uptime`)
- [ ] Install fwlive on armsr guest
- [ ] Stage attribution on `tests/fixtures/logread-2000.json` (median of 5)
- [ ] Record substrate (`qemu-armsr-tcg` vs native virt) + date + git SHA

## Further reading

- [`../armvirt-armsr-testing.md`](../armvirt-armsr-testing.md)
- [`../openwrt-rootfs-x86-docker.md`](../openwrt-rootfs-x86-docker.md) — optional Docker experiment
- [`../../lab/README.md`](../../lab/README.md)

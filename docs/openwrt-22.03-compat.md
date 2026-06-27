# OpenWrt 22.03 Compatibility

## Status

**Supported** on OpenWrt **22.03.7** with the same `luci-app-fwlive` `_all` ipk built from the 22.03 SDK.

OpenWrt **22.03 is EOL** — use only if you cannot upgrade to **23.05+** yet. New deployments should prefer **23.05** or **24.10**.

| Check | Result (lab) |
|-------|----------------|
| SDK build (`x86-64` / 22.03) | Pass |
| `ubus log.read` | Pass |
| `ubus fwlive rules` | Pass |
| LuCI dispatcher + static JS | Pass |
| nft ping log → parser + `rule_label` | Pass |
| x86_64 QEMU smoke (`validate-openwrt-22.03.sh`) | Pass (2026-06-27) |

No separate 22.03 code branch — one feed, one JS view, one parser (same firewall4/nft era as 23.05).

**SDK note:** Official `ghcr.io/openwrt/sdk:armsr-armv8-22.03.7` is not published; build the `_all` ipk with **`x86-64-22.03.7`** (or extract the SDK tarball manually for other hosts). The resulting ipk installs on any architecture.

## Build

```sh
./scripts/docker-sdk.sh build --target x86-64 --version 22.03
# ipk: out/x86_64/22.03.7/fwlive/luci-app-fwlive_*_all.ipk
```

The `_all` arch ipk installs on any target (x86_64, armsr, …).

## Lab validation (quick)

```sh
./scripts/validate-openwrt.sh --version 22.03
# or back-compat: ./scripts/validate-openwrt-22.03.sh
```

Uses **x86_64 + KVM** by default (fast).

### Manual steps

```sh
RELEASE=22.03.7 ./scripts/download-openwrt-x86-64.sh
sudo OWRT_IMG=lab/images/openwrt-x86-64-22.03.7.img ./scripts/qemu-lab-prepare-image.sh
OWRT_RELEASE=22.03.7 ./scripts/run-openwrt-x86-qemu.sh
OWRT_FWLIVE_VERSION=22.03.7 ./scripts/qemu-install-fwlive.sh
./scripts/qemu-smoke-fwlive.sh
```

LuCI: `http://localhost:8080/cgi-bin/luci/admin/status/fwlive` (login required on stock images).

## 22.03-specific lab notes

1. **Image names** — 22.03 armsr ships `generic-ext4-combined.img.gz` (no `-efi` suffix), same pattern as 23.05. Download scripts probe both variants.

2. **Fresh x86 images** — 22.03.7 combined images may ship **without** `/etc/config/network`; `qemu-lab-prepare-image.sh` seeds a DHCP `lan` section before first boot (required for slirp hostfwd SSH).

3. **uhttpd / LuCI** — `qemu-lab-prepare-image.sh` switches `uhttpd` from `lua_prefix` to `ucode_prefix` **only when** `/usr/share/ucode/luci/dispatcher.uc` exists. Stock **22.03.7 x86 combined** lab images use the **lua** dispatcher (no ucode tweak). Some other 22.03 profiles may ship ucode — same prepare logic as [23.05 compat](openwrt-23.05-compat.md).

4. **ext4 journal** — Official `.img.gz` artifacts may need `e2fsck` before first boot (prepare script runs this automatically).

5. **LuCI HTTP 403** — Unauthenticated requests return 403 with `x-luci-login-required: yes`; smoke tests treat this as success (dispatcher reachable).

6. **Log format** — Kernel nft log lines parse correctly on 22.03.7; `rule_label` resolves via `fwlive rules` ubus.

7. **Binary feed** — Install from `https://lucas-albers-lz4.github.io/fwlive-packages/22.03` (22.03-built ipk only; do not reuse 23.05+ packages).

## Expected field variance

- Log line prefixes may vary by image profile and kmod packaging.
- Some targets may emit fewer parsed keys in kernel messages.
- Interface naming and availability of `IN`/`OUT` tokens can differ.

Parser remains tolerant; UI filters degrade missing fields to empty values.

## Acceptance

- LuCI page loads (login or 200) and polls successfully after auth.
- No JS runtime errors when fields are absent.
- Action/interface/protocol/IP filters operate on available data.

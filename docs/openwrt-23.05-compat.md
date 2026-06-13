# OpenWrt 23.05 Compatibility

## Status

**Supported** on OpenWrt **23.05.5** with the same `luci-app-fwlive` `_all` ipk built from the 23.05 SDK.

| Check | Result (lab) |
|-------|----------------|
| SDK build (`armsr-armv8` / 23.05) | Pass |
| `ubus log.read` | Pass |
| `ubus fwlive rules` | Pass |
| LuCI dispatcher + static JS | Pass |
| nft ping log → parser + `rule_label` | Pass |
| x86_64 QEMU smoke (`validate-openwrt-23.05.sh`) | Pass (2026-06-07) |
| armsr QEMU smoke | Same ipk + prepare script; TCG boot is slow (~15–30 min) |

No separate 23.05 code branch — one feed, one JS view, one parser.

## Build

```sh
./scripts/docker-sdk.sh build --target armsr-armv8 --version 23.05
# ipk: out/aarch64_generic/23.05.5/fwlive/luci-app-fwlive_*_all.ipk
```

The `_all` arch ipk installs on any target (x86_64, armsr, …).

## Lab validation (quick)

```sh
./scripts/validate-openwrt.sh --version 23.05
# or back-compat: ./scripts/validate-openwrt-23.05.sh
```

Uses **x86_64 + KVM** by default (fast). For production target:

```sh
./scripts/validate-openwrt.sh --version 23.05 --qemu-target armsr
```

### Manual steps

```sh
RELEASE=23.05.5 ./scripts/download-openwrt-x86-64.sh   # or download-openwrt-armsr-armv8.sh
sudo OWRT_IMG=lab/images/openwrt-x86-64-23.05.5.img ./scripts/qemu-lab-prepare-image.sh
OWRT_RELEASE=23.05.5 ./scripts/run-openwrt-x86-qemu.sh
OWRT_FWLIVE_VERSION=23.05.5 ./scripts/qemu-install-fwlive.sh
./scripts/qemu-smoke-fwlive.sh
```

LuCI: `http://localhost:8080/cgi-bin/luci/admin/status/fwlive` (login required on stock images).

## 23.05-specific lab notes

1. **Image names** — 23.05 armsr ships `generic-ext4-combined.img.gz` (no `-efi` suffix). Download scripts probe both variants.

2. **uhttpd / LuCI** — Many 23.05 images ship `luci-base` with the **ucode** dispatcher (`/usr/share/ucode/luci/dispatcher.uc`) but `uhttpd` still points at legacy `lua_prefix`. `qemu-lab-prepare-image.sh` adds `ucode_prefix` and removes `lua_prefix` when the dispatcher exists.

3. **ext4 journal** — Official `.img.gz` artifacts may need `e2fsck` before first boot (prepare script runs this automatically).

4. **LuCI HTTP 403** — Unauthenticated requests return 403 with `x-luci-login-required: yes`; smoke tests treat this as success (dispatcher reachable).

5. **Log format** — Kernel nft log lines parse correctly on 23.05.5; `rule_label` resolves via `fwlive rules` ubus.

## Expected field variance

- Log line prefixes may vary by image profile and kmod packaging.
- Some targets may emit fewer parsed keys in kernel messages.
- Interface naming and availability of `IN`/`OUT` tokens can differ.

Parser remains tolerant; UI filters degrade missing fields to empty values.

## Acceptance

- LuCI page loads (login or 200) and polls successfully after auth.
- No JS runtime errors when fields are absent.
- Action/interface/protocol/IP filters operate on available data.

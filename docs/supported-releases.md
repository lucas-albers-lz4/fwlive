# Supported OpenWrt releases

One table of record for which OpenWrt releases `luci-app-fwlive` runs on. Per-release lab notes follow. The package is **`_all`** (LuCI JS + shell) — one artifact per release line works on any router architecture.

| Release | Validated patch | Firewall stack | Package format |
|---------|-----------------|----------------|----------------|
| **23.05.x** | **23.05.5** | firewall4 / nft (EOL) | `.ipk` (`opkg`) |
| **24.10.x** | **24.10.8** | firewall4 / nft | `.ipk` (`opkg`) |
| **25.12.x** | **25.12.5** | firewall4 / nft | `.apk` (`apk`) |

**Not supported:** OpenWrt **21.02** / **22.03** and earlier (historical notes below). Prefer **24.10+** for new deployments. `snapshot` is an internal SDK option only.

Install commands: [Installation guide](user/installation.md). Requirements: [Requirements](user/requirements.md).

## 21.02.x (historical)

**Status:** Unsupported. OpenWrt 21.02 is EOL. The published feed and SDK matrix no longer build or ship a `…/21.02` cell. Keep these notes for old lab evidence only; source-build at your own risk.

- Backend is **iptables**. fw3 LOG lines appear as **`kern.warn kernel:`** with netfilter KV fields. The parser handles both that and the `iptables:` tag.
- LuCI uses the **lua_prefix** dispatcher (no ucode). The lab prepare script skips ucode tweaks when `dispatcher.uc` is absent.
- There is no published `…/21.02` feed. A source-built 21.02 ipk is lab-only; do not install a 23.05+ package on 21.02.

The commands used for the old lab are no longer part of the supported SDK
matrix. There is no current build or validation command for 21.02; retain the
scope below only as historical evidence.

Validation scope: app-stack sign-off on **21.02.7 x86-64 QEMU lab** only. Typical fw3 fleets use MIPS/ARM — treat other SoCs as best-effort until hardware or armsr lab is run.

Custom-chain logging (operator enablement, [#7](https://github.com/lucas-albers-lz4/fwlive/issues/7)):

```sh
iptables -N my-debug
iptables -A my-debug -j LOG --log-prefix "my-chain: "
iptables -A my-debug -j ACCEPT
iptables -I INPUT -p icmp --icmp-type echo-request -j my-debug
```

UCI: `option log '1'` on `@rule` entries where supported.

## 22.03.x (historical)

**Status:** Unsupported. OpenWrt 22.03 is EOL. The published feed and SDK matrix no longer build or ship a `…/22.03` cell. Keep these notes for old lab evidence only; source-build at your own risk.

- Same firewall4/nft era as 23.05 — one feed, one JS view, one parser.
- Historical SDK note: `ghcr.io/openwrt/sdk:armsr-armv8-22.03.7` was not published; the old lab used **`x86-64-22.03.7`** for its `_all` ipk.
- Fresh x86 22.03.7 images may ship **without** `/etc/config/network`. The lab prepare script seeds a DHCP `lan` section before first boot.
- There is no published `…/22.03` feed. A source-built 22.03 ipk is lab-only.

There is no current build or validation command for 22.03; the notes above
describe historical lab conditions only.

## 23.05.x

**Status:** Supported (EOL) on **23.05.5**. OpenWrt 23.05 is EOL — prefer **24.10+** for new deployments.

- firewall4/nft. No separate code branch — one feed, one JS view, one parser.
- Build the `_all` ipk from the **armsr-armv8** SDK.
- Many 23.05 images ship the **ucode** dispatcher while `uhttpd` still points at `lua_prefix`. The lab prepare script adds `ucode_prefix` when the dispatcher exists.

Build and validate:

```sh
./scripts/docker-sdk.sh build --target armsr-armv8 --version 23.05
./scripts/validate-openwrt.sh --version 23.05
# default: x86_64 + KVM (fast). Production-shaped target:
# ./scripts/validate-openwrt.sh --version 23.05 --qemu-target armsr
```

## 24.10.x, 25.12.x, snapshot

These lines share the firewall4/nft stack of 23.05. They need no dedicated compat page — see [Requirements](user/requirements.md) and the table above for validated patches. **25.12.x** and **snapshot** use the **apk** package format.

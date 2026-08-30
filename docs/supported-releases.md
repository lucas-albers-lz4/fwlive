# Supported OpenWrt releases

One table of record for which OpenWrt releases `luci-app-fwlive` runs on. Per-release lab notes follow. The package is **`_all`** (LuCI JS + shell) — one artifact per release line works on any router architecture.

| Release | Validated patch | Firewall stack | Package format |
|---------|-----------------|----------------|----------------|
| **21.02.x** | **21.02.7** | fw3 / iptables (legacy, EOL) | `.ipk` (`opkg`) |
| **22.03.x** | **22.03.7** | firewall4 / nft (EOL) | `.ipk` (`opkg`) |
| **23.05.x** | **23.05.5** | firewall4 / nft | `.ipk` (`opkg`) |
| **24.10.x** | **24.10.8** | firewall4 / nft | `.ipk` (`opkg`) |
| **25.12.x** | **25.12.5** | firewall4 / nft | `.apk` (`apk`) |
| **snapshot** | latest | firewall4 / nft | `.apk` (best-effort) |

**Not supported:** releases before **21.02**. Use **21.02.x** for fw3/iptables; **22.03.x** is supported but EOL — prefer **23.05+** for new deployments.

Install commands: [Installation guide](user/installation.md). Requirements: [Requirements](user/requirements.md).

## 21.02.x (legacy fw3)

**Status:** Supported (legacy) on **21.02.7**. OpenWrt 21.02 is EOL — keep it only for operators stuck on fw3/iptables.

- Backend is **iptables**. fw3 LOG lines appear as **`kern.warn kernel:`** with netfilter KV fields. The parser handles both that and the `iptables:` tag.
- LuCI uses the **lua_prefix** dispatcher (no ucode). The lab prepare script skips ucode tweaks when `dispatcher.uc` is absent.
- Install the **21.02-built** ipk only (feed channel `…/21.02`). Do not install a 23.05+ package on 21.02.

Build and validate:

```sh
./scripts/docker-sdk.sh build --target x86-64 --version 21.02
./scripts/validate-openwrt.sh --version 21.02 --sdk-target x86-64
```

Validation scope: app-stack sign-off on **21.02.7 x86-64 QEMU lab** only. Typical fw3 fleets use MIPS/ARM — treat other SoCs as best-effort until hardware or armsr lab is run.

Custom-chain logging (operator enablement, [#7](https://github.com/lucas-albers-lz4/fwlive/issues/7)):

```sh
iptables -N my-debug
iptables -A my-debug -j LOG --log-prefix "my-chain: "
iptables -A my-debug -j ACCEPT
iptables -I INPUT -p icmp --icmp-type echo-request -j my-debug
```

UCI: `option log '1'` on `@rule` entries where supported.

## 22.03.x (EOL)

**Status:** Supported on **22.03.7**. OpenWrt 22.03 is EOL — upgrade to **23.05+** for new deployments.

- Same firewall4/nft era as 23.05 — one feed, one JS view, one parser.
- SDK note: `ghcr.io/openwrt/sdk:armsr-armv8-22.03.7` is not published. Build the `_all` ipk with **`x86-64-22.03.7`** (or extract the SDK tarball manually).
- Fresh x86 22.03.7 images may ship **without** `/etc/config/network`. The lab prepare script seeds a DHCP `lan` section before first boot.
- Install from feed channel `…/22.03` (22.03-built ipk only).

Build and validate:

```sh
./scripts/docker-sdk.sh build --target x86-64 --version 22.03
./scripts/validate-openwrt.sh --version 22.03
```

## 23.05.x

**Status:** Supported on **23.05.5**.

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

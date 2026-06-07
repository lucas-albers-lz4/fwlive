# Requirements

## Router / OpenWrt

| Item | Detail |
|------|--------|
| **Firewall** | **firewall4** (nftables) — menu entry requires `/usr/sbin/nft` |
| **LuCI** | Modern JS LuCI (`luci-base`) |
| **Logging** | `logd` (standard on OpenWrt images) |
| **RPC** | `rpcd` (for `ubus fwlive poll` / `resolve` / `rules`) |

## Supported OpenWrt releases

Validated in this project’s lab for:

| Release | Package format | Notes |
|---------|----------------|-------|
| **23.05.x** | `.ipk` (`opkg`) | LuCI ucode dispatcher; see [23.05 compat](../openwrt-23.05-compat.md) |
| **24.10.x** | `.ipk` (`opkg`) | Primary production target |
| **25.12.x** | `.apk` (`apk`) | Same app; package manager differs |
| **snapshot** | `.apk` | Best-effort; minimal images may omit LuCI |

The application itself has **no per-SoC binaries** — one build runs on any board that ships the dependencies above.

## What you need on the router

- Enough free flash/RAM for an extra LuCI app (small — JS + one rpcd script)
- Firewall rules configured to **log** interesting traffic ([guide](enabling-firewall-logs.md))
- LuCI login with permission to read logs (default admin)

## What you do not need

- Docker, QEMU, or a Linux build host on the router
- OPNsense or any non-OpenWrt software
- Kernel modules beyond normal firewall4

## Build host (only if you compile yourself)

If you build the `.ipk` / `.apk` from source, you need a **Linux x86_64** machine with the OpenWrt SDK or full tree. That is covered in the [developer guide](../developer/README.md), not required for end users who install a prebuilt package.

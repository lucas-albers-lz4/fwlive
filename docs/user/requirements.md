# Requirements

## Router / OpenWrt

| Item | Detail |
|------|--------|
| **OpenWrt** | **23.05+** (minimum; releases before 23.05 are not supported) |
| **Firewall (supported)** | **firewall4** / nftables — default on 23.05+ images |
| **Firewall (best-effort)** | **iptables** LOG when `/usr/sbin/iptables` is present without nft — not guaranteed |
| **LuCI** | Modern JS LuCI (`luci-base`) |
| **Logging** | `logd` (standard on OpenWrt images) |
| **RPC** | `rpcd` (for `ubus fwlive poll` / `resolve` / `rules`) |

Menu entry requires **`/usr/sbin/nft` or `/usr/sbin/iptables`**.

## Supported OpenWrt releases

Validated in this project’s lab for **firewall4**:

| Release | Package format | Notes |
|---------|----------------|-------|
| **23.05.x** | `.ipk` (`opkg`) | LuCI ucode dispatcher; see [23.05 compat](../openwrt-23.05-compat.md) |
| **24.10.x** | `.ipk` (`opkg`) | Primary production target |
| **25.12.x** | `.apk` (`apk`) | Same app; package manager differs |
| **snapshot** | `.apk` | Best-effort; minimal images may omit LuCI |

**iptables LOG** on 23.05+ is **best-effort** (fixture-tested; optional manual validation). This is a **log viewer**, not iptables TRACE — see [iptables logging reference](../fwlive-iptables-logging.md).

The application itself has **no per-SoC binaries** — one build runs on any board that ships the dependencies above.

## What you need on the router

- Enough free flash/RAM for an extra LuCI app (small — JS + one rpcd script)
- Firewall rules configured to **log** interesting traffic ([guide](enabling-firewall-logs.md))
- LuCI login with permission to read logs (default admin)

## What you do not need

- Docker, QEMU, or a Linux build host on the router
- OPNsense or any non-OpenWrt software
- iptables TRACE or nft trace (LOG rules are enough for this app)

## Build host (only if you compile yourself)

If you build the `.ipk` / `.apk` from source, you need a **Linux x86_64** machine with the OpenWrt SDK or full tree. That is covered in the [developer guide](../developer/README.md), not required for end users who install a prebuilt package.

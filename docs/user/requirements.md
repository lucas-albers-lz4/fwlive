# Requirements

## Router / OpenWrt

| Item | Detail |
|------|--------|
| **OpenWrt (primary)** | **24.10+** — firewall4/nft default (maintained) |
| **OpenWrt (23.05.x)** | **23.05.x** — firewall4/nft; **EOL** — lab-tested on 23.05.5 — see [supported releases](../supported-releases.md) |
| **Not supported** | OpenWrt **21.02**, **22.03**, and earlier |
| **Firewall** | **firewall4** / nftables — default on supported images |
| **LuCI** | Modern JS LuCI (`luci-base`) |
| **Logging** | `logd`, `jsonfilter` (hard deps in package metadata; `opkg install` resolves both) |
| **RPC** | `rpcd` (for `ubus fwlive poll` / `resolve` / `rules`) |

The menu entry is controlled by the `luci-app-fwlive` ACL and does not require
an iptables or nftables binary merely to appear. Supported firewall rules use
the firewall4/nft path; iptables-tagged log lines still classify and still
become table rows.

## Supported OpenWrt releases

Validated in this project's lab:

| Release | Package format | Notes |
|---------|----------------|-------|
| **23.05.x** | `.ipk` (`opkg`) | LuCI ucode dispatcher; **EOL** — see [supported releases](../supported-releases.md) |
| **24.10.x** | `.ipk` (`opkg`) | Primary production target |
| **25.12.x** | `.apk` (`apk`) | Same app; package manager differs |

Log lines tagged `iptables` still classify (including `iptables-nft` / `xt_LOG`). Standalone **iptables-legacy** is unsupported and only diagnosed. This is a **log viewer**, not iptables TRACE — see [iptables logging reference](../fwlive-iptables-logging.md).

**23.05.x** uses firewall4/nft like 24.10+ but is **EOL** — upgrade to **24.10+** when possible.

The application itself has **no per-SoC binaries** — one build runs on any board that ships the dependencies above.

## What you need on the router

- Enough free flash/RAM for an extra LuCI app (small — JS + one rpcd script)
- Firewall rules configured to **log** interesting traffic ([guide](enabling-firewall-logs.md))
- LuCI login with the `luci-app-fwlive` ACL (default admin)

## What you do not need

- Docker, QEMU, or a Linux build host on the router
- OPNsense or any non-OpenWrt software
- iptables TRACE or nft trace (LOG rules are enough for this app)

## Build host (only if you compile yourself)

If you build the `.ipk` / `.apk` from source, you need a **Linux x86_64** machine with the OpenWrt SDK or full tree. That is covered in the [developer guide](../developer/README.md), not required for end users who install a prebuilt package.

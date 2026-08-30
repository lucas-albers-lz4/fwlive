# Requirements

## Router / OpenWrt

| Item | Detail |
|------|--------|
| **OpenWrt (primary)** | **23.05+** — firewall4/nft default |
| **OpenWrt (22.03.x)** | **22.03.x** — firewall4/nft; **EOL** — lab-tested on 22.03.7 x86 — see [supported releases](../supported-releases.md) |
| **OpenWrt (legacy fw3)** | **21.02.x** — fw3/iptables primary; EOL release, lab-tested on 21.02.7 x86 — see [supported releases](../supported-releases.md) |
| **Not supported** | Releases before 21.02 |
| **Firewall (22.03+)** | **firewall4** / nftables — default on supported modern images (22.03 is EOL) |
| **Firewall (21.02.x)** | **fw3 / iptables** — `-j LOG` or UCI `option log '1'` on rules you want visible |
| **Firewall (best-effort on 22.03+)** | **iptables** LOG when `/usr/sbin/iptables` is present without nft — not guaranteed |
| **LuCI** | Modern JS LuCI (`luci-base`) |
| **Logging** | `logd` (standard on OpenWrt images) |
| **RPC** | `rpcd` (for `ubus fwlive poll` / `resolve` / `rules`) |

Menu entry requires **`/usr/sbin/nft` or `/usr/sbin/iptables`**.

## Supported OpenWrt releases

Tested in this project’s lab for **firewall4**:

| Release | Package format | Notes |
|---------|----------------|-------|
| **21.02.x** | `.ipk` (`opkg`) | **Legacy fw3/iptables** — install 21.02-built ipk only; see [supported releases](../supported-releases.md) |
| **22.03.x** | `.ipk` (`opkg`) | firewall4/nft; **EOL** — see [supported releases](../supported-releases.md) |
| **23.05.x** | `.ipk` (`opkg`) | LuCI ucode dispatcher; see [supported releases](../supported-releases.md) |
| **24.10.x** | `.ipk` (`opkg`) | Primary production target |
| **25.12.x** | `.apk` (`apk`) | Same app; package manager differs |
| **snapshot** | `.apk` | Best-effort; minimal images may omit LuCI |

**iptables LOG** on **22.03+** is **best-effort** (fixture-tested; optional manual validation). On **21.02.x**, iptables LOG is the **primary** path. This is a **log viewer**, not iptables TRACE — see [iptables logging reference](../fwlive-iptables-logging.md).

**22.03.x** uses firewall4/nft like 23.05+ but is **EOL** — upgrade to 23.05+ when possible.

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

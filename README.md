# fwlive — Firewall Live View for OpenWrt

LuCI **Firewall Live View**: a live, filterable table of firewall **LOG** events on OpenWrt (firewall4/nft on **22.03+**; fw3/iptables on legacy **21.02.x**) — inspired by OPNsense Live View, implemented as a small, portable LuCI app.

![Firewall Live View — Simple view](docs/user/assets/fwlive-simple-view.png)

## What it does

- Polls firewall log lines about **once per second** — no page reload
- Shows **pass** / **drop** (and related actions) with clear styling
- **Simple view** (default) — compact table; click a row to expand the raw log message
- **Show Detail** — one-button toggle to the full 14-column Detailed view
- **Filter** by action, interface, protocol, addresses, ports; quick search across fields
- **Click-to-filter** and **URL hash** state for shareable troubleshooting views
- Resolves **rule names** from fw4/nft or iptables `--log-prefix` metadata where possible

**Menu:** Status → Firewall Live View (`/cgi-bin/luci/admin/status/fwlive`)

Traffic appears only when firewall rules include **`log`**. After install, run the [quick-start commands](docs/user/enabling-firewall-logs.md#quick-start-after-install) (WAN zone logging or ping test) — stock configs log nothing by default.

---

## Supported OpenWrt releases

| Release | Validated patch | Firewall stack | Package format |
|---------|-----------------|----------------|----------------|
| **21.02.x** | **21.02.7** | fw3 / iptables (legacy, EOL) | `.ipk` (`opkg`) |
| **22.03.x** | **22.03.7** | firewall4 / nft (EOL) | `.ipk` (`opkg`) |
| **23.05.x** | **23.05.5** | firewall4 / nft | `.ipk` (`opkg`) |
| **24.10.x** | **24.10.5** | firewall4 / nft | `.ipk` (`opkg`) |
| **25.12.x** | **25.12.0** | firewall4 / nft | `.apk` (`apk`) |
| **snapshot** | latest | firewall4 / nft | `.apk` (best-effort) |

**Not supported:** releases before **21.02**. Use **21.02.x** for fw3/iptables; **22.03.x** is supported but EOL — prefer **23.05+** for new deployments.

The package is **`_all`** (LuCI JS + shell) — one artifact per OpenWrt release line works on any router architecture.

Details: [Requirements](docs/user/requirements.md) · [21.02 compat](docs/openwrt-21.02-compat.md) · [22.03 compat](docs/openwrt-22.03-compat.md) · [23.05 compat](docs/openwrt-23.05-compat.md)

---

## Install

**Recommended — [binary feed](docs/binary-feed.md)** (`opkg` on **21.02–24.10**, `apk` on **25.12+** from GitHub Pages).

**opkg (21.02.x – 24.10.x)** — run on the router; picks the feed for your OpenWrt release:

```sh
BASE='https://lucas-albers-lz4.github.io/fwlive-packages'
. /etc/openwrt_release
feed="$(echo "$DISTRIB_RELEASE" | cut -d. -f1,2)"
case "$feed" in
  21.02|22.03|23.05|24.10) ;;
  *)
    echo "Release $DISTRIB_RELEASE uses apk — use the OpenWrt 25.12+ commands below" >&2
    exit 1
    ;;
esac
wget -O /tmp/fwlive.key "$BASE/public.key"
opkg-key add /tmp/fwlive.key
echo "src/gz fwlive $BASE/$feed" >> /etc/opkg/customfeeds.conf
opkg update && opkg install luci-app-fwlive
```

**apk (25.12+)** — hardcoded example for OpenWrt **25.12**:

```sh
wget -O /tmp/fwlive-feed.rsa.pub https://lucas-albers-lz4.github.io/fwlive-packages/fwlive-feed.rsa.pub
mkdir -p /etc/apk/keys
cp /tmp/fwlive-feed.rsa.pub /etc/apk/keys/fwlive-feed.rsa.pub
echo 'https://lucas-albers-lz4.github.io/fwlive-packages/25.12/all/packages.adb' \
  >> /etc/apk/repositories.d/fwlive.list
apk update && apk add luci-app-fwlive
```

More detail: [binary feed](docs/binary-feed.md) · per-release notes in [21.02](docs/openwrt-21.02-compat.md) / [22.03](docs/openwrt-22.03-compat.md) compat docs.

**Alternative — [GitHub Releases](https://github.com/lucas-albers-lz4/fwlive/releases):** download the package for your OpenWrt version and install manually.

| OpenWrt | Package | Install |
|---------|---------|---------|
| **21.02.x** / **22.03.x** / **23.05.x** / **24.10.x** | `luci-app-fwlive_*_all.ipk` | `opkg install /tmp/luci-app-fwlive_*.ipk` |
| **25.12+** | `luci-app-fwlive-*.apk` | `apk add --allow-untrusted /tmp/luci-app-fwlive-*.apk` |

**Build from feed** (firmware/SDK builders):

```sh
git clone https://github.com/lucas-albers-lz4/fwlive.git
echo "src-link fwlive $(pwd)/fwlive/openwrt-feed" >> feeds.conf
./scripts/feeds update fwlive
./scripts/feeds install luci-app-fwlive
```

Full paths: [Installation guide](docs/user/installation.md) · [Binary feed](docs/binary-feed.md) · [Release workflow](docs/release.md) (maintainers)

---

## Documentation

| I want to… | Start here |
|------------|------------|
| **Install and use** on my router | **[User guide](docs/user/README.md)** |
| **Build, test, or contribute** | **[Developer guide](docs/developer/README.md)** |
| Browse all docs | [docs/README.md](docs/README.md) |
| Release history | [CHANGELOG.md](CHANGELOG.md) |
| FAQ | [docs/FAQ.md](docs/FAQ.md) |

### User guide (highlights)

| Guide | Summary |
|-------|---------|
| [Overview](docs/user/overview.md) | Problem, data flow, when to use it |
| [Requirements](docs/user/requirements.md) | Supported releases, firewall4/fw3, dependencies |
| [Installation](docs/user/installation.md) | opkg, apk, or feed |
| [Using the UI](docs/user/using-the-ui.md) | Controls, filters, screenshots |
| [Enabling logs](docs/user/enabling-firewall-logs.md) | nft/fw4 `log` rules |

### Developer guide (highlights)

| Guide | Summary |
|-------|---------|
| [Environment](docs/developer/environment.md) | Linux x86_64, Docker SDK, QEMU |
| [Architecture](docs/developer/architecture.md) | LuCI JS + ubus + parser sync |
| [Build & test](docs/developer/build-and-test.md) | SDK matrix, validation, smoke |
| [Contributing](docs/developer/contributing.md) | Workflow and acceptance |

---

## Status

**Basic functionality complete** — validated on **21.02.7**, **22.03.7**, **23.05.5**, **24.10.5**, and **25.12.0** (x86 KVM lab). Details: [acceptance criteria](docs/fwlive-acceptance.md).

| Phase | State |
|-------|-------|
| Live table + filters + rule names | Done |
| Multi-version x86 smoke | Done |
| Show hostnames, server-side read | Done — [ROADMAP](docs/ROADMAP.md) |
| Rule overlay, digest/SSE | Backlog |

---

## Repository layout

| Path | Purpose |
|------|---------|
| [`openwrt-feed/luci-app-fwlive/`](openwrt-feed/luci-app-fwlive/) | **Shipped package** |
| [`core/fwlive-log.js`](core/fwlive-log.js) | Parser source of truth |
| [`docs/user/`](docs/user/) | End-user documentation |
| [`docs/developer/`](docs/developer/) | Build & development documentation |
| [`scripts/`](scripts/) | SDK, QEMU lab, tests |
| [`feeds.conf.example`](feeds.conf.example) | Feed wiring template |

---

## Quick start (developers — x86 QEMU lab)

```sh
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
RELEASE=24.10.5 ./scripts/download-openwrt-x86-64.sh
sudo OWRT_IMG=lab/images/openwrt-x86-64-24.10.5.img ./scripts/qemu-lab-prepare-image.sh
OWRT_RELEASE=24.10.5 ./scripts/run-openwrt-x86-qemu.sh
./scripts/qemu-install-fwlive.sh
```

LuCI: http://localhost:8080/cgi-bin/luci/admin/status/fwlive

Full paths: [Developer environment](docs/developer/environment.md) · [QEMU lab](docs/developer/qemu-lab.md)

---

## License

**Apache-2.0** — see **[LICENSE](LICENSE)**. **OPNsense Live View** (BSD 2-Clause) UX reference — see **[ATTRIBUTION.md](ATTRIBUTION.md)**.

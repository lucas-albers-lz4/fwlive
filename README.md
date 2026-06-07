# fwview — Firewall Live View for OpenWrt

LuCI **Firewall Live View**: a live, filterable table of **nftables / firewall4** log events on OpenWrt — inspired by OPNsense Live View, implemented as a small, portable LuCI app.

![Firewall Live View — Simple view](docs/user/assets/fwlive-simple-view.png)

## What it does

- Polls firewall log lines about **once per second** — no page reload
- Shows **pass** / **drop** (and related actions) with clear styling
- **Simple view** (default) — compact table; click a row to expand the raw log message
- **Show Detail** — one-button toggle to the full 14-column Detailed view
- **Filter** by action, interface, protocol, addresses, ports; quick search across fields
- **Click-to-filter** and **URL hash** state for shareable troubleshooting views
- Resolves **rule names** from fw4/nft metadata where possible

**Menu:** Status → Firewall Live View (`/cgi-bin/luci/admin/status/fwlive`)

Traffic appears only when firewall rules include **`log`** — see the [logging guide](docs/user/enabling-firewall-logs.md).

---

## Documentation

| I want to… | Start here |
|------------|------------|
| **Install and use** on my router | **[User guide](docs/user/README.md)** |
| **Build, test, or contribute** | **[Developer guide](docs/developer/README.md)** |
| Browse all docs | [docs/README.md](docs/README.md) |

### User guide (highlights)

| Guide | Summary |
|-------|---------|
| [Overview](docs/user/overview.md) | Problem, data flow, when to use it |
| [Requirements](docs/user/requirements.md) | OpenWrt 23.05 / 24.10 / 25.12, firewall4 |
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

**MVP complete** — stages 1–5 core, stream controls, rule labels. Validated on **23.05**, **24.10**, **25.12** (x86 KVM lab). Details: [acceptance criteria](docs/fwlive-acceptance.md).

| Phase | State |
|-------|-------|
| Live table + filters + rule names | Done |
| Multi-version x86 smoke | Done |
| DNS hover, digest/SSE | Backlog — [ROADMAP](docs/ROADMAP.md) |

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

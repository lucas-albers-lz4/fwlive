# fwview

LuCI **Firewall Live View** for OpenWrt (nftables / firewall4), inspired by OPNsense’s live log UI.

**Goal:** poll-based firewall log table with filters and allow/deny styling — using **kernel/fw4 log lines** as the portable layer. See [`docs/opnsense-liveview-parity.md`](docs/opnsense-liveview-parity.md).

**Status:** MVP complete — see [`docs/fwlive-acceptance.md`](docs/fwlive-acceptance.md). Publish prep: [`docs/github-publish-checklist.md`](docs/github-publish-checklist.md).

## Supported platform

| Role | Supported |
|------|-----------|
| **Build host** (SDK, Docker, `make`) | **Linux x86_64** only |
| **OpenWrt targets** (`.ipk`) | **`_all`** package — any board with nft/fw4 |
| **Lab targets** | **`armsr` / `armv8`** (production), **`x86/64`** (fast KVM UI lab) |
| **OpenWrt versions** | **23.05**, **24.10**, **25.12**, **snapshot** — [`docs/sdk-build-matrix.md`](docs/sdk-build-matrix.md) |
| **macOS** | Edit/test parser locally; builds and QEMU on Linux |

**Start here:** [`docs/dev-environment.md`](docs/dev-environment.md)

## Layout

| Path | Purpose |
|------|---------|
| [`openwrt-feed/luci-app-fwlive/`](openwrt-feed/luci-app-fwlive/) | **Shipped OpenWrt package** |
| [`core/fwlive-log.js`](core/fwlive-log.js) | Parser source of truth (Node tests + CLI) |
| [`docs/`](docs/) | Architecture, acceptance, SDK, QEMU |
| [`scripts/`](scripts/) | SDK driver, QEMU lab, deploy, smoke tests |
| [`tests/`](tests/) | Parser/filter tests (no browser) |
| [`archive/`](archive/) | Unmaintained legacy scripts (macOS, old SDK path) |
| [`scripts/validate-openwrt.sh`](scripts/validate-openwrt.sh) | Build + QEMU smoke for one version — [`docs/validation-matrix.md`](docs/validation-matrix.md) |
| [`feeds.conf.example`](feeds.conf.example) | Feed wiring template |

## Quick start (fast UI lab — x86 QEMU)

```sh
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
RELEASE=24.10.5 ./scripts/download-openwrt-x86-64.sh
sudo OWRT_IMG=lab/images/openwrt-x86-64-24.10.5.img ./scripts/qemu-lab-prepare-image.sh
OWRT_RELEASE=24.10.5 ./scripts/run-openwrt-x86-qemu.sh
./scripts/qemu-install-fwlive.sh
./scripts/fwlive-nft-ping-log.sh add --ssh
./scripts/fwlive-test.sh
```

LuCI: http://localhost:8080/cgi-bin/luci/admin/status/fwlive

## Production path (armsr 24.10)

```sh
./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10
RELEASE=24.10.5 ./scripts/download-openwrt-armsr-armv8.sh
sudo OWRT_IMG=lab/images/openwrt-armsr-armv8.img ./scripts/qemu-lab-prepare-image.sh
./scripts/run-openwrt-armsr-armv8-qemu.sh
./scripts/qemu-install-fwlive.sh
./scripts/qemu-smoke-fwlive.sh
```

## Roadmap

| Phase | State |
| ----- | ----- |
| MVP + stream UI + rule names + filter operators | **Done** |
| 23.05 / armsr validation | **Done** (see acceptance doc) |
| Stage 6 — DNS hover, rule overlay | Backlog |
| Stage 7 — digest/SSE | Backlog |

Details: [`docs/ROADMAP.md`](docs/ROADMAP.md)

## Wire the feed

```sh
# In OpenWrt tree or SDK (after luci feed installed):
echo "src-link fwview /absolute/path/to/fwview/openwrt-feed" >> feeds.conf
./scripts/feeds update fwview && ./scripts/feeds install luci-app-fwlive
```

Or use Docker SDK: `./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10`

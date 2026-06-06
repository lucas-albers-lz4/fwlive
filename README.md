# fwview

LuCI **Firewall Live View** for OpenWrt (nftables / firewall4), inspired by OPNsense’s live log UI.

**Goal:** an OpenWrt package **functionally similar to OPNsense Live View** — poll-based table, filters, allow/deny styling — using **firewall log lines** as the portable layer (not PF vs nft). See [`docs/opnsense-liveview-parity.md`](docs/opnsense-liveview-parity.md).

## Supported platform

| Role | Supported |
|------|-----------|
| **Build host** (SDK, Docker, `make`) | **Linux x86_64** only (e.g. Linux Mint on Intel/AMD) |
| **OpenWrt targets** (`.apk`/`.ipk`) | **`armsr` / `armv8`** (AArch64) and **`x86/64`**; QEMU ARM on x86_64 uses **TCG** |
| **OpenWrt versions** | **23.05**, **24.10**, **snapshot** — [`docs/sdk-build-matrix.md`](docs/sdk-build-matrix.md) |
| **Not supported for builds** | Linux on **ARM**, **macOS**, Windows |

**Start here:** [`docs/dev-environment.md`](docs/dev-environment.md) — download image, SDK Docker build, QEMU, deploy, validate.

## Layout

| Path | Purpose |
|------|---------|
| [`openwrt-feed/luci-app-fwlive/`](openwrt-feed/luci-app-fwlive/) | **Custom OpenWrt feed package** |
| [`docs/dev-environment.md`](docs/dev-environment.md) | **Canonical** Linux x86_64 dev loop |
| [`docs/minimal-build-sdk.md`](docs/minimal-build-sdk.md) | SDK details + fallback fwview Docker image |
| [`docs/armvirt-armsr-testing.md`](docs/armvirt-armsr-testing.md) | QEMU **`armsr`** images and networking |
| [`docs/fwlive-nft-logging.md`](docs/fwlive-nft-logging.md) | Enable **`log`** so the UI shows events |
| [`docs/fwlive-development-plan.md`](docs/fwlive-development-plan.md) | Staged parity roadmap + CLI tests |
| [`scripts/fwlive-test.sh`](scripts/fwlive-test.sh) | Run parser/filter tests (no browser) |
| [`lab/`](lab/) | Optional Podman Compose + **`qemux/qemu`** |
| [`docker-compose.yml`](docker-compose.yml) | **`sdk`** matrix ([`ghcr.io/openwrt/sdk`](https://github.com/openwrt/docker)) + legacy **`sdk`** image |
| [`scripts/docker-sdk.sh`](scripts/docker-sdk.sh) | Multi-version / multi-target SDK builds |
| [`docs/sdk-build-matrix.md`](docs/sdk-build-matrix.md) | **23.05 / 24.10 / snapshot** × **armsr / x86-64** |
| [`scripts/docker-sdk-official-*.sh`](scripts/) | Thin wrappers (default: armsr-armv8 snapshot) |
| [`scripts/run-openwrt-armsr-armv8-qemu.sh`](scripts/run-openwrt-armsr-armv8-qemu.sh) | Host QEMU (**Linux x86_64**) |
| [`scripts/agent-build-and-deploy.sh`](scripts/agent-build-and-deploy.sh) | **`opkg`** install over SSH (**`--legacy-hostfwd`**) |
| [`tests/`](tests/) | Parser tests / bench |
| [`core/`](core/) | OPNsense **`core`** submodule (reference only) |

## Work plan

1. **Environment** — [`docs/dev-environment.md`](docs/dev-environment.md): images + SDK Docker + QEMU on **Linux x86_64**.
2. **Build** — `./scripts/docker-sdk.sh build` (or `build-all` for every version × target).
3. **Run** — `./scripts/run-openwrt-armsr-armv8-qemu.sh` (or **`lab-up.sh`**; same **8080** / **2222** for armsr).
4. **Deploy** — `./scripts/agent-build-and-deploy.sh --legacy-hostfwd --ipk out/aarch64_generic/snapshot/fwview/luci-app-fwlive_*.ipk`.
5. **Validate** — **Status → Firewall Live View** + [`docs/fwlive-acceptance.md`](docs/fwlive-acceptance.md); enable logging per [`docs/fwlive-nft-logging.md`](docs/fwlive-nft-logging.md).
6. **Publish** — [`docs/github-publish-checklist.md`](docs/github-publish-checklist.md) when ready.

**Optional:** full OpenWrt tree build — [`docs/openwrt-full-source-build.md`](docs/openwrt-full-source-build.md) (not the default).

## OPNsense `core` (git submodule)

```sh
git clone --recurse-submodules <fwview-url>
# or: git submodule update --init --recursive
```

See [`.gitmodules`](.gitmodules). Used for Live View reference tracing, not shipped in the `.ipk`.

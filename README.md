# fwview

LuCI **Firewall Live View** for OpenWrt (nftables / firewall4), inspired by OPNsense’s live log UI.

## Development host (SDK builds)

**Recommended:** **Linux x86_64** (e.g. **Ubuntu** desktop). The official OpenWrt SDK is **`Linux-x86_64`**; building on native Linux matches the toolchain, avoids macOS **APFS** case-sensitivity issues, and avoids **Apple Silicon** + Docker **`linux/amd64`** GCC problems. Follow **[`docs/minimal-build-sdk.md`](docs/minimal-build-sdk.md)** — extract the SDK, run **§2–4**, then **`make package/luci-app-fwlive/compile`**, or use optional Docker with a bind mount (**`USE_SDK_BIND=1`**).

**macOS** is still fine for **editing**, **QEMU** testing, and **deploy** helpers; for **compiling the SDK** on a Mac, use the **macOS-specific** Docker volume flow in that doc (**§4a**).

## Layout

| Path | Purpose |
|------|---------|
| [`openwrt-feed/luci-app-fwlive/`](openwrt-feed/luci-app-fwlive/) | **Custom OpenWrt feed package** — use with `src-link` or publish as its own feed repo |
| [`openwrt-feed/README.md`](openwrt-feed/README.md) | Feeds install steps for OpenWrt 24.10+ |
| [`lab/`](lab/) | Podman Compose + QEMU lab stubs |
| [`docker-compose.yml`](docker-compose.yml) | Optional **linux/amd64** SDK environment; **named volume** (mainly for **macOS**) or bind mount on **Linux** |
| [`scripts/docker-sdk-import-tar.sh`](scripts/docker-sdk-import-tar.sh) | Loads **`.tar.zst`** into the Docker volume (**macOS** / case-insensitive hosts) |
| [`scripts/docker-sdk-setup-feeds.sh`](scripts/docker-sdk-setup-feeds.sh) | **`feeds`** + **`luci-app-fwlive`** + **`defconfig`** inside the volume |
| [`scripts/docker-sdk-make.sh`](scripts/docker-sdk-make.sh) | Runs **`make package/.../compile`** (see [`docs/minimal-build-sdk.md`](docs/minimal-build-sdk.md) §4a) |
| [`scripts/agent-build-and-deploy.sh`](scripts/agent-build-and-deploy.sh) | **`scp`/`opkg`** to guest **:22**; optional lease/MAC discovery; **`--legacy-hostfwd`** |
| [`docs/`](docs/) | Schema, acceptance, OPNsense parity; **[`opnsense-liveview-understanding.md`](docs/opnsense-liveview-understanding.md)** (PF vs nft / logging) |
| [`tests/`](tests/) | Parser/bench sanity checks (Node) |
| [`core/`](core/) | **Git submodule** — [OPNsense `core`](https://github.com/opnsense/core) (read-only reference; not part of fwview source history) |
| `luci/`, `openwrt/`, `firewall4/` | Optional local clones for reference (not submodules) |

## OPNsense `core` (git submodule)

This repo uses a **[git submodule](https://git-scm.com/book/en/v2/Git-Tools-Submodules)** at **`core/`** pointing to **`https://github.com/opnsense/core.git`**. **fwview** does **not** vendor OPNsense’s files: only the **pinned commit** is recorded (see [`.gitmodules`](.gitmodules)). Clone or pull with:

```sh
git clone --recurse-submodules <fwview-url>   # or after clone:
git submodule update --init --recursive
```

Update the reference to the latest upstream commit (optional):

```sh
cd core && git fetch origin && git checkout master && git pull
cd .. && git add core && git commit -m "Bump opnsense/core submodule"
```

The application **does not** need to live inside the upstream `luci` git tree: OpenWrt pulls many packages from separate feeds; this package follows that model.

## Minimal build (recommended)

You **do not** need to build OpenWrt firmware images—**download** official **`armsr/armv8`** images and the matching **SDK** tarball. On **Linux x86_64**, extract the SDK and build **on the host** (or use Docker with **`USE_SDK_BIND=1`**). Add this repo’s feed inside the SDK, compile **only** `luci-app-fwlive`, install the `.ipk` with `opkg`.

Step-by-step: **[`docs/minimal-build-sdk.md`](docs/minimal-build-sdk.md)**  
QEMU ARM virt (`armsr` / “armvirt”): **[`docs/armvirt-armsr-testing.md`](docs/armvirt-armsr-testing.md)**  
Feed wiring (full buildroot or SDK): [`openwrt-feed/README.md`](openwrt-feed/README.md) · [`feeds.conf.example`](feeds.conf.example)  
SDK in Docker/Podman (`linux/amd64`): [`docker-compose.yml`](docker-compose.yml), [`docker-compose.bind.yml`](docker-compose.bind.yml) (optional Linux bind mount), [`build/openwrt-sdk.Dockerfile`](build/openwrt-sdk.Dockerfile)

## Work plan (in order)

1. **Images** — **download** official **`armsr/armv8`** combined EFI + `u-boot` (see [`docs/armvirt-armsr-testing.md`](docs/armvirt-armsr-testing.md), `scripts/download-openwrt-armsr-armv8.sh`). No firmware image build required.
2. **SDK build** — **download** the matching **24.10 `armsr/armv8` SDK** **`.tar.zst`**. On **Ubuntu / Linux x86_64**, extract it, run **§2–4** in **[`docs/minimal-build-sdk.md`](docs/minimal-build-sdk.md)**, then **`make package/luci-app-fwlive/compile`** (or **`./scripts/docker-sdk-make.sh`** with **`USE_SDK_BIND=1`** + **`OPENWRT_SDK_MOUNT`**). **macOS only:** use the Docker **volume** scripts **`docker-sdk-import-tar.sh`** / **`docker-sdk-setup-feeds.sh`** / **`docker-sdk-make.sh`** (**§4a**) because of APFS and optional **Apple Silicon** GCC issues.
3. **Deploy** — `scp`/`ssh` to the guest or router on **port 22**; LuCI on **80**/**443**. For **QEMU on macOS with vmnet** (no hostfwd), use the guest’s real IP (e.g. from **`/var/db/dhcpd_leases`** + QEMU **`mac=`**). **`scripts/agent-build-and-deploy.sh`** automates discover + install. **Do not** rely on **`127.0.0.1:2222`** / **`:8080`** unless you use **`--legacy-hostfwd`** with explicit QEMU user-net **hostfwd**.
4. **Validate** — **Status → Firewall Live View**; if empty, add **`log`** to nft/fw4 rules. See [`docs/minimal-build-sdk.md`](docs/minimal-build-sdk.md) §6.
5. **Lab (optional)** — Podman Compose in `lab/` (needs disk images); QEMU: **`scripts/run-openwrt-armsr-armv8-qemu.sh`** (defaults to **vmnet**; legacy user-net **hostfwd** is commented in-file).
6. **Publish** — when ready, push to GitHub; see [`docs/github-publish-checklist.md`](docs/github-publish-checklist.md) (no i18n required for now).

## Quick build hook

See [`feeds.conf.example`](feeds.conf.example) and [`openwrt-feed/README.md`](openwrt-feed/README.md).

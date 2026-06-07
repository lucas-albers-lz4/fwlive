# Development environment (Linux x86_64)

> **Prefer:** [Developer guide → Environment](developer/environment.md) · [Build & test](developer/build-and-test.md)

Canonical setup for **fwview**: cross-build **`luci-app-fwlive`** on **Linux x86_64**, test on **OpenWrt `armsr` / `armv8`** in QEMU.

## Build host vs OpenWrt target

| Role | Architecture | Notes |
|------|----------------|--------|
| **Build host** | **Linux x86_64** only | OpenWrt publishes SDKs as **`…Linux-x86_64.tar.zst`**. Do not use Linux **aarch64**, **macOS**, or **ARM Mac** as the compile host. |
| **OpenWrt targets** | **`armsr` / `armv8`** (AArch64), **`x86/64`** | Package dirs: **`aarch64_generic`**, **`x86_64`**. QEMU ARM guest uses TCG on x86_64. |
| **OpenWrt versions** | **23.05**, **24.10**, **25.12**, **snapshot** | [`sdk-build-matrix.md`](sdk-build-matrix.md) · smoke: [`validation-matrix.md`](validation-matrix.md) |

## Quick start

### 1. Host packages (Mint / Ubuntu)

```sh
sudo apt install build-essential libncurses-dev gawk docker.io docker-compose-v2 \
  qemu-system-arm curl git nodejs
```

Podman users: `podman` + `podman-compose` for [`lab/`](../lab/) instead of Docker where noted.

### 2. Download QEMU disk image (runtime)

```sh
RELEASE=24.10.5 ./scripts/download-openwrt-armsr-armv8.sh
```

Uses official [downloads.openwrt.org](https://downloads.openwrt.org/releases/) **`armsr/armv8`** combined EFI + U-Boot under **`lab/images/`**.

### 3. Build `.apk` / `.ipk` (official OpenWrt SDK container — recommended)

```sh
./scripts/docker-sdk.sh list
./scripts/docker-sdk.sh build                              # armsr-armv8 + snapshot (default)
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build-all                          # all 6 version × target cells
```

Legacy one-liners (same default cell):

```sh
./scripts/docker-sdk-official-setup-feeds.sh
./scripts/docker-sdk-official-make.sh
./scripts/docker-sdk-official-copy-out.sh
```

Uses **[`ghcr.io/openwrt/sdk`](https://github.com/openwrt/docker)** (`linux/amd64`). Artifacts: **`out/<arch>/<version>/fwview/`** — see [`sdk-build-matrix.md`](sdk-build-matrix.md).

**Fallback:** archived tarball SDK path — [`archive/scripts/`](../archive/scripts/) (prefer `docker-sdk.sh`).

**Native (no Docker):** extract SDK on host — [`minimal-build-sdk.md`](minimal-build-sdk.md) §2–4.

### 4. Run QEMU guest

**Host QEMU (recommended for deploy script):**

```sh
./scripts/run-openwrt-armsr-armv8-qemu.sh
```

- LuCI: **http://127.0.0.1:8080**
- SSH: **`ssh -p 2222 root@127.0.0.1`**
- Two **user** netdevs (WAN + LAN); **hostfwd** on LAN only.

**Lab (Podman Compose + `qemux/qemu`):** **armsr** service uses the **same** host ports (**8080** / **2222**) — see [`lab/README.md`](../lab/README.md).

### 5. Install package and validate

```sh
./scripts/agent-build-and-deploy.sh --legacy-hostfwd \
  --ipk out/aarch64_generic/snapshot/fwview/luci-app-fwlive_*.ipk
```

Install **`luci-base`** ipk first if the image has no LuCI.

Open **Status → Firewall Live View**. If empty, add **`log`** to fw4/nft rules — [`fwlive-nft-logging.md`](fwlive-nft-logging.md).

Acceptance: [`fwlive-acceptance.md`](fwlive-acceptance.md) · OPNsense parity: [`opnsense-liveview-parity.md`](opnsense-liveview-parity.md).

## What we do not support

- **Compiling** OpenWrt on **ARM hosts** or **macOS**
- **Full firmware** `make world` as the default loop — optional only: [`openwrt-full-source-build.md`](openwrt-full-source-build.md)
- **Vagrant** full-build VMs (heavy; not maintained here)

Legacy **macOS** QEMU (vmnet): [`archive/scripts/legacy/`](../archive/scripts/legacy/) — unmaintained. Builds require Linux x86_64.

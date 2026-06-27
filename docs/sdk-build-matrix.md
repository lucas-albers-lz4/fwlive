# SDK build matrix (OpenWrt versions × targets)

Cross-build **`luci-app-fwlive`** for multiple OpenWrt releases and CPU targets from a **Linux x86_64** host using official **[`ghcr.io/openwrt/sdk`](https://github.com/openwrt/docker)** images.

## Matrix

| OpenWrt version | Image tag suffix | Notes |
|-----------------|------------------|--------|
| **snapshot** (latest) | *(none)* | Same as `armsr-armv8` / `x86-64` without suffix |
| **25.12** | `-25.12.0` | Current stable release |
| **24.10** | `-24.10.5` | Pinned to current 24.10 point release |
| **23.05** | `-23.05.5` | Pinned to current 23.05 point release |
| **22.03** | `-22.03.7` | EOL — published **opkg** feed (`…/22.03`); SDK image **x86-64 only** on ghcr.io |
| **21.02** | `-21.02.7` | Legacy fw3/iptables — published **opkg** feed (`…/21.02`) |

| Target | SDK image prefix | Package arch dir |
|--------|------------------|------------------|
| **armsr-armv8** | `ghcr.io/openwrt/sdk:armsr-armv8` | `aarch64_generic` |
| **x86-64** | `ghcr.io/openwrt/sdk:x86-64` | `x86_64` |

**Twelve cells** by default: 6 versions × 2 targets (22.03 armsr SDK image not published — use x86-64 build for `_all` ipk).

Each cell uses its **own Docker volume** (separate SDK tree + `.config`). First use runs `./setup.sh` inside the container to download the matching SDK archive.

## Quick start

```sh
./scripts/docker-sdk.sh list

# One cell (defaults: armsr-armv8 + snapshot — same as legacy sdk-official)
./scripts/docker-sdk.sh setup
./scripts/docker-sdk.sh make
./scripts/docker-sdk.sh copy-out

# Or setup + make + copy-out in one step
./scripts/docker-sdk.sh build --target x86-64 --version 24.10

# Parallel compile (default -j8 on 8+ cores; this host has 16 — use more if you like)
OWRT_MAKE_JOBS=16 ./scripts/docker-sdk.sh make --target x86-64
./scripts/docker-sdk.sh make -j 4
```

Artifacts land under:

```text
out/<package-arch>/<version>/fwlive/luci-app-fwlive-*.apk
```

Examples:

- `out/aarch64_generic/snapshot/fwlive/…`
- `out/aarch64_generic/24.10.5/fwlive/…`
- `out/x86_64/22.03.7/fwlive/…`
- `out/x86_64/23.05.5/fwlive/…`

Legacy flat path `out/aarch64_generic/fwlive/` is no longer written by default; use the versioned subdirs above.

## Build everything

```sh
# All 6 cells (feeds setup runs once per volume)
./scripts/docker-sdk.sh build-all

# Subset
./scripts/docker-sdk.sh build-all --target x86-64
./scripts/docker-sdk.sh build-all --version 23.05
```

Expect **long runtime** on first `build-all` (six SDK downloads + six feed setups). The **x86-64** cells (especially **snapshot**) may compile a large slice of the **`base`** feed on first `make` (kernel modules, nftables stack); subsequent builds are incremental.

Pinned point releases: **25.12 → 25.12.0**, **24.10 → 24.10.5**, **23.05 → 23.05.5**, **22.03 → 22.03.7** (override with full patch in `--version` if needed).

QEMU smoke per version: [`validation-matrix.md`](validation-matrix.md).

## Legacy wrappers

These still work and default to **armsr-armv8 + snapshot**:

```sh
./scripts/docker-sdk-official-setup-feeds.sh
./scripts/docker-sdk-official-make.sh
./scripts/docker-sdk-official-copy-out.sh
```

Pass matrix options through them:

```sh
./scripts/docker-sdk-official-make.sh --target x86-64 --version 24.10
```

## Deploy hints

| Runtime | Package path |
|---------|----------------|
| QEMU **armsr** guest | `out/aarch64_generic/<version>/fwlive/*.apk` |
| **x86** Docker experiment | `out/x86_64/<version>/fwlive/*.apk` |

```sh
./scripts/agent-build-and-deploy.sh --legacy-hostfwd \
  --ipk out/aarch64_generic/snapshot/fwlive/luci-app-fwlive_*.ipk

./scripts/docker-rootfs-x86-install-fwlive.sh \
  out/x86_64/snapshot/fwlive/luci-app-fwlive-*.apk
```

## Environment overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `OWRT_SDK_TARGET` | `armsr-armv8` | Default target for `docker-sdk.sh` |
| `OWRT_SDK_VERSION` | `snapshot` | Default version |
| `FWLIVE_MOUNT` | `.` | Repo mount inside SDK container |

Docker Compose service **`sdk`** reads `OWRT_SDK_IMAGE` and `OWRT_SDK_VOLUME` (set automatically by `scripts/lib/sdk-matrix.sh`). Service **`sdk-official`** remains a fixed alias for the original default volume.

## Feeds note

Setup enables the **`base`** feed and installs **`liblua`**, **`libucode`**, and related packages before **`luci-base`**. The official SDK image is minimal; without this step **`lucihttp`** fails with missing `lua.h` / `ucode/module.h`. See [`minimal-build-sdk.md`](minimal-build-sdk.md).

## Related docs

- [`dev-environment.md`](dev-environment.md) — QEMU + default build loop
- [`minimal-build-sdk.md`](minimal-build-sdk.md) — native SDK / fallback image
- [`openwrt-rootfs-x86-docker.md`](openwrt-rootfs-x86-docker.md) — x86 LuCI smoke test

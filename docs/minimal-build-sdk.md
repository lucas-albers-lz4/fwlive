# Minimal build: SDK only (no full image)

For **proving `luci-app-fwlive` and deploying an `.ipk`**, use the **OpenWrt SDK** for the **same OpenWrt release and target** as your **router or VM image**. You do **not** need to compile a full firmware image.

**Canonical loop:** [Developer guide → Environment](developer/environment.md).

**Optional full tree:** [`openwrt-full-source-build.md`](openwrt-full-source-build.md) — slow; not the default.

---

## Build host: Linux x86_64 only

| | |
|-|-|
| **Compile host** | **Linux x86_64** (Intel/AMD). SDK tarballs are **`…Linux-x86_64.tar.zst`**. |
| **Not supported** | Linux **aarch64**, **macOS**, Windows as compile hosts |
| **Targets** | **`armsr` / `armv8`** (`aarch64_generic`) and **`x86/64`** (`x86_64`); QEMU ARM guest is emulated on x86_64 |
| **Versions** | **21.02**, **22.03**, **23.05**, **24.10**, **25.12**, **snapshot** — [`sdk-build-matrix.md`](sdk-build-matrix.md) |

**Host packages:** `sudo apt install build-essential libncurses-dev gawk` (optional: `jsmin`, `csstidy`).

---

## Recommended: official OpenWrt SDK Docker image

On **Linux x86_64**, prefer **[`ghcr.io/openwrt/sdk`](https://github.com/openwrt/docker)** via the build matrix (see [`sdk-build-matrix.md`](sdk-build-matrix.md)):

```sh
./scripts/docker-sdk.sh list
./scripts/docker-sdk.sh build                                    # armsr-armv8 + snapshot
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build-all                                # 21.02–snapshot × both targets (22.03: x86-64 only)
```

Legacy wrappers (same default cell):

```sh
./scripts/docker-sdk-official-setup-feeds.sh
./scripts/docker-sdk-official-make.sh
./scripts/docker-sdk-official-copy-out.sh
```

The container runs **`./setup.sh`** on first use to download the matching SDK (no manual `.tar.zst` import).

`docker-sdk-official-setup-feeds.sh` also enables the **`base`** feed and installs **`liblua`**, **`libucode`**, and related packages. The official SDK image is minimal: LuCI pulls **`lucihttp`**, which needs Lua 5.1 and ucode headers from **`feeds/base`**, not only from **`luci`** / **`packages`**. If you see `lua.h: No such file or directory` or `ucode/module.h: No such file or directory`, re-run setup.

---

## Fallback: manual SDK tarball

### 1. Get the SDK

- From [OpenWrt downloads](https://downloads.openwrt.org/releases/), open **24.10.x** → **targets** → **armsr** → **armv8** (for QEMU ARM64 testing).
- Download the **OpenWrt SDK** `.tar.zst` (same release as your VM image).
- Extract somewhere short (e.g. `~/openwrt-sdk`).

```sh
mkdir -p .sdk && tar -C .sdk -xf ~/Downloads/openwrt-sdk-24.10.*-armsr-armv8_*_musl.Linux-x86_64.tar.zst
# → .sdk/openwrt-sdk-24.10-.../   ← cd here for steps 2–4
```

### 2. Prepare feeds inside the SDK

```sh
cd ~/openwrt-sdk
test -f feeds.conf || cp feeds.conf.default feeds.conf
./scripts/feeds update luci packages
./scripts/feeds install luci-base
```

### 3. Add this project as a feed

Use an **absolute path** to your checkout's `openwrt-feed` directory:

```sh
echo "src-link fwlive /path/to/fwlive/openwrt-feed" >> feeds.conf
./scripts/feeds update fwlive
./scripts/feeds install luci-app-fwlive
```

See [`feeds.conf.example`](../feeds.conf.example).

### 4. Build the package only

```sh
make defconfig
make package/luci-app-fwlive/compile V=s
```

The `.ipk` appears under `bin/packages/.../luci/luci-app-fwlive_*.ipk` (exact path varies by arch).

### 4a. Compile with Docker (optional; same result as §4)

If you already completed steps 1–4 on the host, you can point Docker at that tree:

```sh
export OPENWRT_SDK_MOUNT=/path/to/extracted-sdk
export USE_SDK_BIND=1
docker compose build
./scripts/docker-sdk-make.sh
```

### 5. Deploy on the router or QEMU guest

#### Typical LAN router

```sh
scp bin/packages/*/luci/luci-app-fwlive_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'opkg install /tmp/luci-app-fwlive_*.ipk'
```

#### Linux: QEMU user networking (hostfwd)

```sh
./scripts/agent-build-and-deploy.sh --legacy-hostfwd --ipk bin/packages/*/luci/luci-app-fwlive_*.ipk
```

LuCI: **`http://127.0.0.1:8080`**, SSH: **`ssh -p 2222 root@127.0.0.1`**.

#### macOS QEMU with vmnet (no host port forwarding)

Use the guest's real IP and port 22 for SSH/SCP:

```sh
scp -o StrictHostKeyChecking=no bin/packages/*/luci/luci-app-fwlive_*.ipk root@<guest-ip>:/tmp/luci-app-fwlive.ipk
ssh -o StrictHostKeyChecking=no root@<guest-ip> 'opkg install /tmp/luci-app-fwlive.ipk'
```

Or use the helper:

```sh
export QEMU_MAC_LAN=52:54:00:44:55:66
./scripts/agent-build-and-deploy.sh --ipk bin/packages/*/luci/luci-app-fwlive_*.ipk
```

## 6. Post-deploy: run the checks

Open **Status → Firewall Live View**. If empty, add **`log`** to fw4/nft rules — see [enabling firewall logs](user/enabling-firewall-logs.md).

---

## When you would use a full buildroot instead

Custom kernel, non-default feeds baked into the image, or reproducible OEM-style images. Not required for this LuCI package alone.

---

## Troubleshooting / edge cases

## Expected noise during feed setup

OpenWrt's SDK often prints many lines like **`has a dependency on 'libubox', which does not exist`** while **`scripts/feeds`** scans Makefiles. This is **usually harmless** for **`make package/luci-app-fwlive/compile`**.

Similarly, **`tmp/.config-package.in` … redefinition** and **`Config-build.in` … defaults for choice** are common **kconfig** merge warnings.

If you see **`tmp/.packagedeps: … unterminated variable reference`**, run **`rm -rf tmp`** in the SDK tree and **`make defconfig`** again.

## `lua.h: No such file or directory` or `ucode/module.h: No such file or directory`

Re-run `docker-sdk-official-setup-feeds.sh` — do not skip the base-feed step. The official SDK image is minimal; LuCI needs headers from **`feeds/base`**.

## Apple Silicon Mac: Docker `linux/amd64` and GCC segfaults

Official OpenWrt SDKs are **Linux x86_64** host binaries. On **Apple Silicon**, the Docker `linux/amd64` container runs under CPU emulation. The cross-compiler (GCC) often **segfaults** under emulation when CMake runs a compile test (as in `lucihttp`).

**Practical options:**

1. **Preferred:** build on **Linux x86_64** (Ubuntu desktop) — matches the published SDK host.
2. Keep macOS for editing but use **`docker context`** / **SSH** to a remote **x86_64** Docker host.
3. Try another engine (Docker Desktop "Use Rosetta for x86/amd64", OrbStack, Colima); success varies.

## Case-insensitive filesystem errors

Bind-mounting an SDK from **macOS** (APFS is case-insensitive) causes:

```text
OpenWrt can only be built on a case-sensitive filesystem
```

Use the **volume workflow** (`docker-sdk-import-tar.sh`) so the SDK lives on a case-sensitive filesystem inside Docker, not a macOS bind mount.

## `No rule to make target 'package/luci-app-fwlive/compile'`

Feeds not installed or **`make defconfig`** not run — run **`docker-sdk-setup-feeds.sh`** (volume) or complete steps 2–4 above (bind mount).

## macOS deployment: finding the guest IP

Match your QEMU **`mac=`** for the LAN NIC to **`hw_address`** in **`/var/db/dhcpd_leases`** (no `sudo` required).

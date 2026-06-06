# Minimal build: SDK only (no full image)

For **proving `luci-app-fwlive` and deploying an `.ipk`**, use the **OpenWrt SDK** for the **same OpenWrt release and target** as your **router or VM image**. You do **not** need to compile a full firmware image.

**Canonical loop:** [`dev-environment.md`](dev-environment.md).

**Optional full tree:** [`openwrt-full-source-build.md`](openwrt-full-source-build.md) — slow; not the default.

## Build host: Linux x86_64 only

| | |
|-|-|
| **Compile host** | **Linux x86_64** (Intel/AMD). SDK tarballs are **`…Linux-x86_64.tar.zst`**. |
| **Not supported** | Linux **aarch64**, **macOS**, Windows as compile hosts |
| **Targets** | **`armsr` / `armv8`** (`aarch64_generic`) and **`x86/64`** (`x86_64`); QEMU ARM guest is emulated on x86_64 |
| **Versions** | **23.05**, **24.10**, **snapshot** — [`sdk-build-matrix.md`](sdk-build-matrix.md) |

**Host packages:** `sudo apt install build-essential libncurses-dev gawk` (optional: `jsmin`, `csstidy`).

## Recommended build: official OpenWrt SDK Docker image

On **Linux x86_64**, prefer **[`ghcr.io/openwrt/sdk`](https://github.com/openwrt/docker)** via the build matrix (see [`sdk-build-matrix.md`](sdk-build-matrix.md) and [`dev-environment.md`](dev-environment.md)):

```sh
./scripts/docker-sdk.sh list
./scripts/docker-sdk.sh build                                    # armsr-armv8 + snapshot
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build-all                                # 23.05, 24.10, snapshot × both targets
```

Legacy wrappers (same default cell):

```sh
./scripts/docker-sdk-official-setup-feeds.sh
./scripts/docker-sdk-official-make.sh
./scripts/docker-sdk-official-copy-out.sh
```

The container runs **`./setup.sh`** on first use to download the matching SDK (no manual `.tar.zst` import).

`docker-sdk-official-setup-feeds.sh` also enables the **`base`** feed and installs **`liblua`**, **`libucode`**, and related packages. The official SDK image is minimal: LuCI pulls **`lucihttp`**, which needs Lua 5.1 and ucode headers from **`feeds/base`**, not only from **`luci`** / **`packages`**. If you see `lua.h: No such file or directory` or `ucode/module.h: No such file or directory`, re-run setup (do not skip the base-feed step).

### Fallback: fwview SDK image + volume (§4a below)

Use **`docker-sdk-import-tar.sh`** / **`docker-sdk-setup-feeds.sh`** / **`docker-sdk-make.sh`** if the official image path does not work for your feed layout.

## Current focus: QEMU ARM virtual (`armsr`)

For **armvirt-style** testing on OpenWrt **24.10**, use target **`armsr`** / **`armv8`** (AArch64) — see **[`armvirt-armsr-testing.md`](armvirt-armsr-testing.md)** for image names, QEMU, and terminology.  
**x86_64** can use the same SDK flow once you switch to that target’s SDK.

## 1. Get the SDK (download; do not build the SDK)

- From [OpenWrt downloads](https://downloads.openwrt.org/releases/), open **24.10.x** → **targets** → **armsr** → **armv8** (for QEMU ARM64 testing).
- Download the **OpenWrt SDK** `.tar.zst` from that same directory (same release as your **downloaded** VM image), e.g.  
  `openwrt-sdk-24.10.0-armsr-armv8_gcc-*_musl.Linux-x86_64.tar.zst`.
- Extract somewhere short (e.g. `~/openwrt-sdk`).

**Host note:** published SDKs are **Linux x86_64** host binaries. **Primary workflow:** develop on **Linux Mint / Ubuntu x86_64** (or similar), extract and build **natively** on the host (**§2–4** + **§4**).

Extract the SDK tarball somewhere stable (example: **`~/openwrt-sdk/`** or **`.sdk/openwrt-sdk-…/`** — the **inner** directory must contain **`Makefile`** and **`scripts/feeds`**):

```sh
mkdir -p .sdk && tar -C .sdk -xf ~/Downloads/openwrt-sdk-24.10.*-armsr-armv8_*_musl.Linux-x86_64.tar.zst
# → .sdk/openwrt-sdk-24.10-.../   ← cd here for steps 2–4
```

**macOS-only Docker:** do **not** bind-mount an extracted SDK from the Mac filesystem — APFS is case-insensitive. Use the **§4a** volume workflow (**`docker-sdk-import-tar.sh`**) so the SDK lives on a **case-sensitive** filesystem inside Docker.

Optional **Docker** on **Linux** (same `make` result): **after** feeds + **`make defconfig`** on the **host** or via **`docker-sdk-setup-feeds.sh`** in a volume, see **§4a**. Without **`./scripts/feeds install luci-app-fwlive`**, **`make package/luci-app-fwlive/compile`** fails with **no rule to make target**.

## 2. Prepare feeds inside the SDK

```sh
cd ~/openwrt-sdk
test -f feeds.conf || cp feeds.conf.default feeds.conf
./scripts/feeds update luci packages
./scripts/feeds install luci-base
```

## 3. Add this project as a feed

Use an **absolute path** to your checkout’s `openwrt-feed` directory (or a `src-git` URL after you publish to GitHub):

```sh
echo "src-link fwview /path/to/fwview/openwrt-feed" >> feeds.conf
./scripts/feeds update fwview
./scripts/feeds install luci-app-fwlive
```

## 4. Build the package only

```sh
make defconfig
make package/luci-app-fwlive/compile V=s
```

The `.ipk` appears under `bin/packages/.../luci/luci-app-fwlive_*.ipk` (exact path varies by arch).

### 4a. Compile with Docker / Podman (optional; same result as §4)

Use this **instead of** running `make` directly on the host when you want an isolated toolchain (optional on **Linux**; often needed on **macOS**).

#### Linux x86_64 (Mint / Ubuntu): optional Docker with bind mount

If you already completed **§2–4** on the host under a path on **ext4** (or another case-sensitive filesystem), you can point Docker at that tree:

```sh
export OPENWRT_SDK_MOUNT=/path/to/extracted-sdk
export USE_SDK_BIND=1
docker compose build
./scripts/docker-sdk-make.sh
```

Or: `docker compose -f docker-compose.yml -f docker-compose.bind.yml run --rm sdk-bind make package/luci-app-fwlive/compile V=s`

#### macOS / ARM compile hosts (not supported)

**fwview** does not support compiling the SDK on **macOS** or **Linux aarch64**. Use a **Linux x86_64** machine (or x86_64 VM) with **`sdk-official`** or native SDK.

The legacy **`sdk`** + volume import scripts remain for reference only.

To copy **`.ipk`** files to the host (example **`./out/`**):

```sh
mkdir -p out
docker compose run --rm -v "$PWD/out:/out" sdk-legacy cp -a /openwrt-sdk/bin/packages/. /out/
```

#### Last resort (not recommended)

If you must bind-mount from a case-insensitive host, `FORCE=1 make …` can bypass the check; only use if you accept possible odd failures.

**Troubleshooting**

| Error | Cause |
| ----- | ----- |
| `OpenWrt can only be built on a case-sensitive filesystem` | Bind-mounted SDK from **macOS** — use **§4a** volume flow (`docker-sdk-import-tar.sh`), not **`OPENWRT_SDK_MOUNT`** on the host. |
| `No rule to make target 'package/luci-app-fwlive/compile'` | Feeds not installed or **`make defconfig`** not run — run **`docker-sdk-setup-feeds.sh`** (volume) or complete §2–4 (bind mount). |
| `No Makefile` / empty tree | Import failed or wrong path — re-run **`docker-sdk-import-tar.sh`** or fix **`OPENWRT_SDK_MOUNT`**. |
| **`Segmentation fault`** when running **`aarch64-openwrt-linux-musl-gcc`**, CMake **“C compiler … broken”**, **`lucihttp`** / **`luci-base`** compile fails | Most common with **Docker `linux/amd64` on Apple Silicon**. **Native builds on Linux x86_64** (e.g. Ubuntu desktop) avoid this. Details: **Apple Silicon + Docker** below. |

##### Apple Silicon Mac only: `linux/amd64` Docker and GCC segfaults

If you still compile the SDK **on a Mac** (not on **Ubuntu x86_64**): official OpenWrt SDKs are **Linux x86_64** host binaries. Our compose file uses **`platform: linux/amd64`**. On **Apple Silicon**, that container runs under **CPU emulation** (QEMU / Rosetta-style paths depending on Docker engine). The **cross-compiler and host tools** are heavy **x86_64** ELFs; **GCC often segfaults** under that stack when CMake runs a compile test (as in **`lucihttp`**), which is an environment limitation—not a bug in **`luci-app-fwlive`**.

**Practical options:**

1. **Preferred:** build on **Linux x86_64** (e.g. **Ubuntu** desktop) — **matches** the published SDK host (**`…Linux-x86_64.tar.zst`**), so the toolchain runs **without** CPU emulation.
2. Keep macOS for editing but use **`docker context`** / **SSH** to a remote **x86_64** Docker host.
3. Try another engine/settings (**Docker Desktop** “Use Rosetta for x86/amd64” or similar, **OrbStack**, **Colima**); success varies.

**What about an ARM build VM instead of x86_64?** For **`armsr/armv8`**, OpenWrt **24.10.x** currently publishes the SDK only as **`Linux-x86_64`** (see the [download directory](https://downloads.openwrt.org/releases/) for your release). So an **aarch64 Linux VM** does **not** get a matching native SDK from that tarball—you would still be running **x86_64** host binaries (via Docker **`linux/amd64`** or **`qemu-x86_64`** on the VM). That may be **more stable** than on Docker Desktop for Mac, but it is **not** the same as “everything native ARM.” The reliable fix remains a **x86_64 Linux** environment for this SDK, unless a future release adds a **`Linux-aarch64`** (or similar) SDK for your target and you switch the container/platform to **arm64** accordingly.

#### Expected noise during `./scripts/docker-sdk-setup-feeds.sh`

OpenWrt’s SDK often prints **many lines** like **`has a dependency on 'libubox', which does not exist`** (also **`rpcd`**, **`firewall4`**, **`lua/host`**, firmware package names, etc.) while **`scripts/feeds`** and **`make defconfig`** scan Makefiles. In the SDK tree those packages usually **do** exist under **`package/`** or appear once the full index is built; the checker runs **before** the graph is complete, so this is **usually harmless** for **`make package/luci-app-fwlive/compile`**.

Similarly, **`tmp/.config-package.in` … redefinition** and **`Config-build.in` … defaults for choice** are common **kconfig** merge warnings.

If you see **`tmp/.packagedeps: … unterminated variable reference`**, stale **`tmp/`** can confuse **`make`**. The setup script removes **`tmp/`** before **`defconfig`**; if it still appears, run **`rm -rf tmp`** in the SDK tree and **`make defconfig`** again.

If **`docker-sdk-make.sh`** says feeds are not configured but you already ran **`docker-sdk-setup-feeds.sh`**, that was a **false negative**: **`feeds/fwview/`** is usually a **symlink** to **`/work/fwview/openwrt-feed`**, and plain **`find`** does not follow symlinked directories. The script uses **`find -L`** (or explicit **`test -f`**) so the check matches OpenWrt’s layout.

## 5. Deploy on the router or QEMU guest

### Typical LAN router

```sh
scp bin/packages/*/luci/luci-app-fwlive_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'opkg install /tmp/luci-app-fwlive_*.ipk'
```

### Linux: QEMU user networking (hostfwd) — default for `run-openwrt-armsr-armv8-qemu.sh`

On **Linux x86_64**, the repo’s QEMU helper uses **`-netdev user`** with **host 2222→guest 22** and **8080→80** (see [`armvirt-armsr-testing.md`](armvirt-armsr-testing.md)). Use **`127.0.0.1`** and the **`--legacy-hostfwd`** flag on the deploy script:

```sh
./scripts/agent-build-and-deploy.sh --legacy-hostfwd --ipk bin/packages/*/luci/luci-app-fwlive_*.ipk
```

LuCI: **`http://127.0.0.1:8080`**, SSH: **`ssh -p 2222 root@127.0.0.1`**.

### macOS QEMU with vmnet (no host port forwarding)

Use the guest’s **real IP** and **port 22** for SSH/SCP, and **80** / **443** for LuCI. **Do not** assume **`127.0.0.1:2222`** or **`:8080`** unless you explicitly run QEMU with **user** networking and **hostfwd** (not the default for vmnet).

- Find the guest IP: match your QEMU **`mac=`** for the LAN NIC to **`hw_address`** in **`/var/db/dhcpd_leases`** (no `sudo` required to read this file on current macOS).
- Copy/install:

```sh
scp -o StrictHostKeyChecking=no bin/packages/*/luci/luci-app-fwlive_*.ipk root@<guest-ip>:/tmp/luci-app-fwlive.ipk
ssh -o StrictHostKeyChecking=no root@<guest-ip> 'opkg install /tmp/luci-app-fwlive.ipk'
```

Or use the helper (discovers IP from **`QEMU_MAC_LAN`** / **`QEMU_MAC_WAN`** if **`OPENWRT_HOST`** is unset):

```sh
export QEMU_MAC_LAN=52:54:00:44:55:66   # same as your QEMU -device ... mac=...
./scripts/agent-build-and-deploy.sh --ipk bin/packages/*/luci/luci-app-fwlive_*.ipk
```

**Legacy hostfwd** (same as Linux flow): `OPENWRT_HOST=127.0.0.1` with QEMU mapping **host 2222→guest 22** and **8080→80**:

```sh
./scripts/agent-build-and-deploy.sh --legacy-hostfwd --ipk path/to/luci-app-fwlive_*.ipk
```

Resolve any `opkg` dependency prompts (`luci-base`, `firewall4`, etc.) per your image.

## 6. Post-deploy: validate Firewall Live View (LuCI)

If the table is empty, see **[`fwlive-nft-logging.md`](fwlive-nft-logging.md)**.

After install, open **Status → Firewall Live View** (requires **`/usr/sbin/nft`**).

- If the table stays **empty**, add **nft/fw4 rules that `log`** for the traffic you are testing. The UI reads **`ubus log.read`** / logd, not raw `nft` counters.
- On the device: `logread -f` or **System Log** in LuCI should show firewall lines once rules log traffic.

This matches the same checklist as a full buildroot image — only the transport to the guest differs (vmnet vs LAN).

## When you would use a full buildroot instead

- Custom kernel, non-default feeds baked into the image, or reproducible OEM-style images. Not required for this LuCI package alone.

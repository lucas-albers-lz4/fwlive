# QEMU ARM virtual testing (`armvirt` workflow)

Colloquially people still say **“armvirt”** for *OpenWrt in QEMU on a virtual ARM machine*. In current OpenWrt trees, that role is filled by the **`armsr`** target (**Arm SystemReady**), subtargets **`armv7`** (32-bit) and **`armv8`** (64-bit / AArch64).

**Recommendation for fwlive:** use **`armsr` / `armv8`** on OpenWrt **24.10**. **Prefer downloading** official images from [downloads.openwrt.org](https://downloads.openwrt.org/releases/) instead of building them. Reserve **x86_64** for later.

## 1. Download images (preferred)

From the release tree, e.g. **24.10.0** (adjust the path if you use a newer **24.10.x** point release):

**Directory:** `releases/<version>/targets/armsr/armv8/`

| What | File (example for 24.10.0) |
|------|----------------------------|
| QEMU disk | `openwrt-24.10.0-armsr-armv8-generic-ext4-combined-efi.img.gz` |
| U-Boot (QEMU) | `u-boot-qemu_armv8/u-boot.bin` |
| Optional quick test | `openwrt-24.10.0-armsr-armv8-generic-initramfs-kernel.bin` (RAM boot, no persistence) |

**SDK** (same folder): `openwrt-sdk-24.10.0-armsr-armv8_gcc-*_musl.Linux-x86_64.tar.zst` — use this to build `luci-app-fwlive` (see [`minimal-build-sdk.md`](minimal-build-sdk.md)).

### Helper (repo)

```sh
RELEASE=24.10.0 ./scripts/download-openwrt-armsr-armv8.sh
```

Writes **`lab/images/openwrt-armsr-armv8.img`** and **`lab/images/u-boot-qemu_armv8.bin`** (paths are gitignored).

## 2. SDK / package arch (for `luci-app-fwlive`)

Build the `.ipk` with the SDK that matches **the same release and `armsr/armv8` target** as the running image. Do **not** mix 24.10.0 image with a snapshot SDK.

| Topic | Note |
|-------|------|
| Typical toolchain triple | `aarch64-openwrt-linux-musl` (from SDK) |
| SDK host | **`Linux-x86_64` only** — use [`dev-environment.md`](dev-environment.md) / official **`ghcr.io/openwrt/sdk:armsr-armv8`**. Not supported on ARM or macOS hosts. |

Then build **`luci-app-fwlive`** with the SDK ([`minimal-build-sdk.md`](minimal-build-sdk.md)) or a full OpenWrt tree ([`openwrt-full-source-build.md`](openwrt-full-source-build.md)).

## QEMU lab on this machine (important)

1. **Stop Docker** if it holds ports 2222/8080: `docker stop owrt-x64-exp`
2. **Prepare images once** (relaxed firewall, HTTP-only uhttpd, ucode LuCI path):
   ```sh
   sudo ./scripts/qemu-lab-prepare-image.sh
   sudo OWRT_IMG=lab/images/openwrt-x86-64.img ./scripts/qemu-lab-prepare-image.sh
   ```
3. **Networking (verified, same as x86 lab):** single **`-nic user,hostfwd=...`** + guest LAN **DHCP**. Prepare the image before first boot:
   ```sh
   sudo OWRT_IMG=lab/images/openwrt-armsr-armv8.img ./scripts/qemu-lab-prepare-image.sh
   ```
   (Also clears root password for lab SSH — armsr images may ship with a hash; x86 lab images are usually already blank.)
   Legacy dual-NIC mode: `OWRT_QEMU_DUAL_NIC=1` (not recommended). QEMU uses:
   - `-nic user,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22`
   - LuCI **http://localhost:8080/cgi-bin/luci/** · SSH **`ssh -p 2222 root@localhost`**
4. **Static guest IP (optional):** `OWRT_LAB_NET_MODE=static` plus `OWRT_LAB_SUBNET` / `OWRT_LAB_IP` before prepare + run scripts.
5. **Serial console** if needed: `nc 127.0.0.1:4445` (armsr) or `:4444` (x86).
6. **x86_64 + KVM** (fast UI lab on an Intel/AMD host): `./scripts/run-openwrt-x86-qemu.sh` (needs `qemu-system-x86` / `ovmf`).
7. **armsr** (production target): `./scripts/run-openwrt-armsr-armv8-qemu.sh` (TCG — boot is slow).

## 3. Run in QEMU (armv8, EFI + U-Boot)

After download (or manual `gunzip` of the `.img.gz`):

```sh
./scripts/run-openwrt-armsr-armv8-qemu.sh
```

Defaults expect **`lab/images/openwrt-armsr-armv8.img`** and **`lab/images/u-boot-qemu_armv8.bin`**. Override with `OWRT_IMG` / `OWRT_UBOOT` if needed.

The script picks **QEMU networking by OS**:

- **Linux (e.g. Linux Mint x64):** two **`-netdev user`** instances (**WAN** then **LAN**), same **MAC** order as macOS (**`52:54:00:11:22:33`**, **`52:54:00:44:55:66`**). **hostfwd** (**8080→80**, **2222→22**) is on the **LAN** netdev only. **`-accel tcg`**, no **sudo**. Deploy with **`./scripts/agent-build-and-deploy.sh --legacy-hostfwd`**. **LuCI:** `http://127.0.0.1:8080` · **SSH:** `ssh -p 2222 root@127.0.0.1`.

Equivalent manual command for **Linux** user networking:

```sh
qemu-system-aarch64 -nographic \
  -cpu cortex-a53 -machine virt -accel tcg \
  -bios /path/to/u-boot.bin \
  -smp 1 -m 1024 \
  -device virtio-rng-pci \
  -drive file=/path/to/openwrt-armsr-armv8.img,format=raw,index=0,media=disk \
  -netdev user,id=wan0 \
  -device virtio-net-pci,netdev=wan0,mac=52:54:00:11:22:33 \
  -netdev user,id=lan0,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=lan0,mac=52:54:00:44:55:66
```

On **Apple Silicon macOS**, **aarch64** guests use **TCG** (or **hvf** only in the macOS/vmnet path above—**not** the same as **KVM** on Linux). On **x86_64 Linux**, this **armsr** guest is **emulated** (**TCG**); boot is CPU-heavy but avoids macOS/Docker SDK issues when you build **on the host**.

## 4. Initramfs quick boot (optional, download only)

Download **`generic-initramfs-kernel.bin`** from the same `armsr/armv8` directory, then:

```sh
qemu-system-aarch64 -machine virt -cpu cortex-a57 -nographic \
  -kernel openwrt-*-armsr-armv8-generic-initramfs-kernel.bin
```

No persistent disk; useful for quick smoke tests.

## 5. Optional: OpenWrt `qemustart`

From a full OpenWrt **source** tree, `scripts/qemustart` supports **`armsr`** — only needed if you already have a build dir.

## Common mix-ups

- **Toolchain** (`openwrt-toolchain-…tar.zst`) is only a cross-compiler bundle. To build **LuCI packages** with feeds, use the **SDK** (`openwrt-sdk-…tar.zst`) from the same `armsr/armv8` directory.
- **Disk image** can stay named `openwrt-24.10.0-armsr-armv8-generic-ext4-combined-efi.img`; `scripts/run-openwrt-armsr-armv8-qemu.sh` picks that pattern up automatically under `lab/images/`.
- **U-Boot** (`u-boot-qemu_armv8/u-boot.bin`) is still required for the QEMU `-bios` line even when the `.img` is already downloaded.

## Terminology

- **`armsr`** = in-tree name for this QEMU/EFI-oriented ARM profile.
- **`armvirt`** = older wording; use **`armsr`** when choosing downloads or `menuconfig` for 24.10.

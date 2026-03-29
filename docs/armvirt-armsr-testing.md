# QEMU ARM virtual testing (`armvirt` workflow)

Colloquially people still say **“armvirt”** for *OpenWrt in QEMU on a virtual ARM machine*. In current OpenWrt trees, that role is filled by the **`armsr`** target (**Arm SystemReady**), subtargets **`armv7`** (32-bit) and **`armv8`** (64-bit / AArch64).

**Recommendation for fwview:** use **`armsr` / `armv8`** on OpenWrt **24.10**. **Prefer downloading** official images from [downloads.openwrt.org](https://downloads.openwrt.org/releases/) instead of building them. Reserve **x86_64** for later.

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
| SDK host | Official SDKs are often **`Linux-x86_64`**. On **macOS**, run the SDK inside **Linux** (container/VM/CI) if no native SDK matches your host. |

Then follow [`minimal-build-sdk.md`](minimal-build-sdk.md).

## 3. Run in QEMU (armv8, EFI + U-Boot)

After download (or manual `gunzip` of the `.img.gz`):

```sh
./scripts/run-openwrt-armsr-armv8-qemu.sh
```

Defaults expect **`lab/images/openwrt-armsr-armv8.img`** and **`lab/images/u-boot-qemu_armv8.bin`**. Override with `OWRT_IMG` / `OWRT_UBOOT` if needed.

### Primary (macOS): vmnet — guest IP on the LAN

The repo script defaults to **vmnet** NICs (bridged). There is **no** QEMU **hostfwd**; use the guest’s **real IP** for **SSH port 22** and **LuCI on 80 / 443**. Discover the address by matching each QEMU **`mac=`** to **`hw_address`** in **`/var/db/dhcpd_leases`** (no `sudo` needed to read it on current macOS). Deploy the `.ipk` with **`scripts/agent-build-and-deploy.sh`** or manual `scp`/`ssh` — see [`minimal-build-sdk.md`](minimal-build-sdk.md) §5.

### Alternative: user networking + hostfwd (optional)

If you use **`-netdev user`** with explicit port forwarding, **LuCI** may be **`http://127.0.0.1:8080`** (host → guest `:80`) and **SSH** **`ssh -p 2222 root@127.0.0.1`** when mapped **2222→22**. This is **not** the vmnet workflow above.

Example:

```sh
qemu-system-aarch64 -nographic \
  -cpu cortex-a53 -machine virt \
  -bios /path/to/u-boot.bin \
  -smp 1 -m 1024 \
  -device virtio-rng-pci \
  -drive file=/path/to/openwrt-armsr-armv8.img,format=raw,index=0,media=disk \
  -netdev user,id=testlan,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=testlan \
  -netdev user,id=testwan -device virtio-net-pci,netdev=testwan
```

Use **`./scripts/agent-build-and-deploy.sh --legacy-hostfwd`** for install over **2222**/**8080** in that setup.

On **macOS**, QEMU often uses **TCG** (emulation); boot is slower than KVM on Linux. **hvf** applies to **x86_64** guests on Apple Silicon, not to **aarch64** system emulation in the same way—expect CPU emulation cost unless you use a Linux host with KVM for this guest.

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

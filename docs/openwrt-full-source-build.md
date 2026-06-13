# Full OpenWrt source: tools + toolchain (no SDK tarball)

> **Optional / not the default.** For day-to-day **fwlive** work use the **SDK** on **Linux x86_64** — [`dev-environment.md`](dev-environment.md) and [`minimal-build-sdk.md`](minimal-build-sdk.md). Only use this doc if you need a custom firmware image or full buildroot.

If you prefer **not** to download the **SDK** `.tar.zst`, check out the **OpenWrt buildroot** for the same release as your image (e.g. **24.10**), wire in this repo’s feed, then build **host tools** and the **cross toolchain** inside the tree. The first run is **slow** and needs **disk space** (~15 GB+ is common), but setup is straightforward: one git clone, standard feed commands, then **`make tools/install`** and **`make toolchain/install`** before compiling the package.

**When to use this:** comfortable with a long first compile; want to avoid juggling a separate SDK tree.  
**When to use the SDK instead:** faster cold start — see [`minimal-build-sdk.md`](minimal-build-sdk.md).

## 1. Host prerequisites (Linux x86_64)

Install the usual OpenWrt [build dependencies](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem) (Debian/Ubuntu/Mint example):

```sh
sudo apt update
sudo apt install build-essential clang flex bison g++ gawk gcc-multilib gettext \
  git libncurses5-dev libssl-dev python3-distutils rsync unzip zlib1g-dev file wget
```

Use **`libncurses-dev`** instead of **`libncurses5-dev`** on newer distros if the package was renamed.

## 2. Check out OpenWrt and feeds

```sh
git clone https://git.openwrt.org/openwrt/openwrt.git
cd openwrt
git checkout openwrt-24.10   # match your QEMU image / router release

test -f feeds.conf || cp feeds.conf.default feeds.conf
./scripts/feeds update luci packages
./scripts/feeds install luci-base
```

## 3. Add the `fwlive` feed and install the package

Use an **absolute path** to this repo’s **`openwrt-feed`** directory:

```sh
echo "src-link fwlive /absolute/path/to/fwlive/openwrt-feed" >> feeds.conf
./scripts/feeds update fwlive
./scripts/feeds install luci-app-fwlive
```

## 4. Select the target (must match your device / QEMU image)

For **`armsr` / `armv8`** (same family as the downloaded QEMU disk in [`armvirt-armsr-testing.md`](armvirt-armsr-testing.md)):

```sh
make menuconfig
```

Set **Target System** → **Arm SystemReady (EFI) compatible** (or equivalent **`armsr`** wording), **Subtarget** → **armv8 (64-bit)**. Save and exit.

**Without `menuconfig`:** seed **`armsr` / `armv8` / Generic EFI** (matches the usual QEMU **`combined-efi`** image), then expand defaults:

```sh
rm -f .config
printf '%s\n' \
  'CONFIG_TARGET_armsr=y' \
  'CONFIG_TARGET_armsr_armv8=y' \
  'CONFIG_TARGET_armsr_armv8_DEVICE_generic=y' \
  > .config
make defconfig
```

## 5. Build tools, then toolchain, then the package

OpenWrt’s usual order for a from-scratch tree:

```sh
make download          # optional; fetches sources early
make tools/install -j$(nproc)
make toolchain/install -j$(nproc)
make package/luci-app-fwlive/compile V=s
```

The **`/install`** targets finish each stage into the build system’s staging dirs; that is what people mean when they say they “ran **`make tools`** and **`make toolchain`**” in a full tree.

Then install the `.ipk` on the guest or router as in [`minimal-build-sdk.md`](minimal-build-sdk.md) §5 (`opkg` / `scp`).

## Notes

- **Time:** `tools/install` + `toolchain/install` can take **tens of minutes to hours** on first run, depending on CPU and disk.
- **Same release:** OpenWrt **branch**, **downloaded QEMU image**, and **router firmware** should all be the **same 24.10.x** line when you care about binary compatibility.
- **Full image:** you still do **not** need to build a firmware image to test **`luci-app-fwlive`** — only the package build is required unless you want a custom image.

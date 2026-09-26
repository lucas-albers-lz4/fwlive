# Lab targets (Podman + QEMU)

## Prerequisites

- **Linux Mint** (or other **x86_64** Linux) — current primary dev host
- `podman compose`, `qemu-system-aarch64` (e.g. `sudo apt install podman podman-compose qemu-system-arm` on Mint/Ubuntu; `podman compose` uses the `podman-compose` provider)

## Expected image files (prefer download over build)

- **`lab/images/openwrt-armsr-armv8-<RELEASE>.img`** + **`u-boot-qemu_armv8-<RELEASE>.bin`** — official **`armsr/armv8`** artifacts (see [`docs/armvirt-armsr-testing.md`](../docs/armvirt-armsr-testing.md)). Default symlink `openwrt-armsr-armv8.img` → 24.10.8.

  ```sh
  RELEASE=24.10.8 ./scripts/download-openwrt-armsr-armv8.sh
  RELEASE=23.05.5 ./scripts/download-openwrt-armsr-armv8.sh
  ```

  **Version validation:** [supported releases](../docs/supported-releases.md) · `./scripts/validate-openwrt-23.05.sh` · `./scripts/validate-openwrt.sh --version 24.10`

- **`lab/images/openwrt-x86-64-<RELEASE>.img`** — official x86/64 QEMU disk (`targets/x86/64/`). Default symlink `openwrt-x86-64.img` → 24.10.8 (what compose mounts).

  ```sh
  RELEASE=24.10.8 ./scripts/download-openwrt-x86-64.sh
  RELEASE=23.05.5 ./scripts/download-openwrt-x86-64.sh
  ```
- `lab/images/opnsense-amd64.img` — optional reference VM

## Usage

- Start all targets: `./scripts/lab-up.sh`
- Stop all targets: `./scripts/lab-down.sh`

## Ports

Single-guest QEMU (`run-openwrt-*-qemu.sh`): LuCI **8080**, SSH **2222**. Do not
run both guests on those defaults at once.

Dual-arch matrix (`scripts/qemu-smoke-matrix.sh`) and this compose file:

- OpenWrt x86_64: LuCI `http://localhost:8080`, SSH **2222** (`uname -m` = `x86_64`)
- OpenWrt armsr/armv8: LuCI `http://localhost:8081`, SSH **2223** (`uname -m` = `aarch64`)
- OPNsense Web UI: `https://localhost:8443`, SSH **2224**

See [Developer guide → Environment](../docs/developer/environment.md) for the full loop.

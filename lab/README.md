# Lab targets (Podman + QEMU)

## Prerequisites

- **Linux Mint** (or other **x86_64** Linux) — current primary dev host
- `podman`, `podman-compose`, `qemu-system-aarch64` (e.g. `sudo apt install podman podman-compose qemu-system-arm` on Mint/Ubuntu)

## Expected image files (prefer download over build)

- **`lab/images/openwrt-armsr-armv8.img`** + **`lab/images/u-boot-qemu_armv8.bin`** — official **24.10 `armsr/armv8`** artifacts (see [`docs/armvirt-armsr-testing.md`](../docs/armvirt-armsr-testing.md)).

  ```sh
  RELEASE=24.10.0 ./scripts/download-openwrt-armsr-armv8.sh
  ```

- `lab/images/openwrt-x64.img` — x86_64 (future; download from `targets/x86/64/` when needed)
- `lab/images/opnsense-amd64.img` — optional reference VM

## Usage

- Start all targets: `./scripts/lab-up.sh`
- Stop all targets: `./scripts/lab-down.sh`

## Ports

- OpenWrt x64 LuCI: `http://localhost:8081`
- OpenWrt armsr (ARM64 virt) LuCI: `http://localhost:8080` (SSH host **2222** — same as [`run-openwrt-armsr-armv8-qemu.sh`](../scripts/run-openwrt-armsr-armv8-qemu.sh))
- OPNsense Web UI: `https://localhost:8443`

See [`docs/dev-environment.md`](../docs/dev-environment.md) for the full loop.

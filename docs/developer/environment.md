# Development environment

Canonical setup: **Linux x86_64** build host, cross-compile for OpenWrt, test in **QEMU** (x86 KVM fast path or armsr production path).

Full detail: [`../dev-environment.md`](../dev-environment.md) (legacy redirect — content consolidated here).

## Roles

| Role | Architecture | Notes |
|------|--------------|-------|
| **Build host** | Linux **x86_64** only | Official SDKs are `Linux-x86_64` tarballs |
| **Package output** | `aarch64_generic`, `x86_64` | Under `out/<arch>/<version>/fwlive/` |
| **Lab guests** | x86_64 KVM, armsr/armv8 TCG | x86 for daily UI work; armsr for production sign-off |
| **macOS** | Editor + `fwlive-test.sh` only | No SDK/QEMU in this repo’s supported path |

## Host packages (Debian / Ubuntu / Mint)

```sh
sudo apt install build-essential libncurses-dev gawk docker.io docker-compose-v2 \
  qemu-system-x86 qemu-system-arm curl git nodejs
```

## Minimal loop (x86 lab — ~5 commands)

```sh
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
RELEASE=24.10.5 ./scripts/download-openwrt-x86-64.sh
sudo OWRT_IMG=lab/images/openwrt-x86-64-24.10.5.img ./scripts/qemu-lab-prepare-image.sh
OWRT_RELEASE=24.10.5 ./scripts/run-openwrt-x86-qemu.sh
./scripts/qemu-install-fwlive.sh
```

LuCI: http://localhost:8080/cgi-bin/luci/admin/status/fwlive  
SSH: `ssh -p 2222 root@localhost`

## Production-shaped loop (armsr 24.10)

```sh
./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10
RELEASE=24.10.5 ./scripts/download-openwrt-armsr-armv8.sh
sudo OWRT_IMG=lab/images/openwrt-armsr-armv8-24.10.5.img ./scripts/qemu-lab-prepare-image.sh
OWRT_RELEASE=24.10.5 ./scripts/run-openwrt-armsr-armv8-qemu.sh
./scripts/qemu-install-fwlive.sh
./scripts/qemu-smoke-fwlive.sh
```

## OpenWrt versions

| Key | Lab slug | Package mgr |
|-----|----------|-------------|
| 21.02 | 21.02.7 | opkg / `.ipk` (fw3 legacy, EOL) |
| 22.03 | 22.03.7 | opkg / `.ipk` (fw4, EOL — SDK build x86-64 only) |
| 23.05 | 23.05.5 | opkg / `.ipk` |
| 24.10 | 24.10.5 | opkg / `.ipk` |
| 25.12 | 25.12.0 | apk |
| snapshot | snapshot | apk (minimal image — build-only for QEMU smoke) |

See [`../sdk-build-matrix.md`](../sdk-build-matrix.md).

## Theme tint matrix (lab overlay)

Row tint and alternating (zebra) stripe must stay visible under Bootstrap and Material (issues #14, #15). This is a **lab overlay** check — it may `opkg`/`apk` install `luci-theme-material` on the guest. It is **not** part of published-feed smoke.

Prereqs: QEMU guest running, `luci-app-fwlive` installed, host has Node + Playwright.

```sh
./scripts/qemu-install-fwlive.sh
./scripts/qemu-theme-tint-smoke.sh
```

Optional overrides: `OPENWRT_SSH_PORT`, `OWRT_HOSTFWD_HTTP`, `FWLIVE_URL`.

What it asserts:

1. Guest `fwlive.js` includes scoped `--fwlive-pass-color` / Material `var(--success-color, …)` / rgba base rules and `--fwlive-bg-medium` / `var(--white-color-low, …)` for zebra
2. Under Bootstrap and Material, with Row tint **off**, alt vs non-alt row backgrounds differ (zebra paint delta)
3. Under Bootstrap and Material, toggling Row tint changes a **non-alt** row background (pass/deny paint delta)

Host-only (no guest): `./scripts/fwlive-test.sh` covers CSS hardening + tint helper unit tests.

## Next

- [Build & test](build-and-test.md)
- [QEMU lab details](qemu-lab.md)

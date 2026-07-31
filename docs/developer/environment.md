# Development environment

Canonical setup: **Linux x86_64** build host, cross-compile for OpenWrt, test in **QEMU** (x86 KVM fast path or armsr production path).

See: [`../dev-environment.md`](../dev-environment.md) (stub note redirecting to this guide).

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

What the theme-tint smoke asserts:

1. Guest `css.js` includes scoped `--fwlive-pass-color` / Material `var(--success-color, …)` (classic) and `var(--info-color, …)` (accessible) / rgba bases and `--fwlive-bg-medium` / `var(--white-color-low, …)` for zebra
2. Under Bootstrap and Material, with Row tint **Off**, alt vs non-alt row backgrounds differ (zebra paint delta)
3. Under Bootstrap and Material, **Classic** and **Accessible** modes each change a **non-alt** row background (pass/deny paint delta)

Host-only (no guest): `./scripts/fwlive-test.sh` covers CSS hardening + tint helper unit tests.

## Live View UI reliability (lab overlay)

Poll error banner, hostname toggle race, pause/resume, filter debounce, and poll leak on leave/revisit — Playwright against QEMU (#71):

```sh
./scripts/qemu-install-fwlive.sh
./scripts/qemu-ui-reliability-smoke.sh
```

Optional overrides: `OPENWRT_SSH_PORT`, `OWRT_HOSTFWD_HTTP`, `FWLIVE_URL`.

What it asserts:

1. Aborting `fwlive.poll` shows a **Connection lost** status, then clears after the route is restored
2. Rapid hostname checkbox toggles leave rows in the table and raise no `pageerror`
3. Pause then resume keeps a usable table (status not stuck on connection lost)
4. Filter search input is debounced (few tbody mutations for rapid keystrokes); action select rebuilds promptly
5. Leaving Live View stops `fwlive.poll` traffic; revisit does not runaway-poll

## Device edge cases (#72)

Opportunistic lab checks — do not block release. Host unit coverage already exists for most of these.

### Reload failure revert (#64)

Force `/etc/init.d/firewall reload` to fail and assert WAN log UCI rolls back with `firewall_reload_failed`:

```sh
./scripts/qemu-reload-revert-smoke.sh
```

### Space-separated logread times (#66)

Host CI already covers parse/sync (`tests/fwlive-parser-sync.test.js`, `tests/fwlive-parser-filter.test.js`) for `YYYY-MM-DD HH:MM:SS`. Lab guests typically emit classic syslog (`Fri Jul 31 …`) or unix `time` via ubus — no reliable space-timestamp sample on device. Treat as **unit-covered; lab N/A**.

### LuCI i18n spot-check (#46)

PO completeness is gated by `tests/fwlive-i18n.test.js`. Device UI check (installs `luci-i18n-base-*` + `luci-i18n-fwlive-*` from `out/`):

```sh
./scripts/qemu-i18n-spotcheck.sh
```

Translations ship as separate packages (`luci-i18n-fwlive-de`, …), not inside `luci-app-fwlive`. PO dirs must use luci.mk language codes (`de`, `ru`, `zh_Hans` → package `zh-cn`).

## Next

- [Build & test](build-and-test.md)
- [QEMU lab details](qemu-lab.md)

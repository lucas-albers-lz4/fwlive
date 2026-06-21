# Validation matrix (versions × architectures)

End-to-end validation reuses the flow proven on **23.05.5 x86** — generalized into shared scripts.

## Principles

1. **Baseline first** — parser tests + script sanity (`validate-baseline.sh`).
2. **Build all versions** — `_all` ipk; one SDK build per OpenWrt release is enough for QEMU smoke.
3. **Smoke on x86 KVM** — fast loop per version (`smoke-x86`).
4. **Smoke armsr separately** — same scripts, longer TCG boot (~15–30 min).
5. **No hardware-specific code** — one ipk per release; ARM vs x86 lab is QEMU choice only.

## Matrix

| OpenWrt | Release patch | SDK image tag | QEMU lab |
|---------|---------------|---------------|----------|
| **snapshot** | *(latest)* | `armsr-armv8` / `x86-64` | **build only** (minimal image, no LuCI) |
| **25.12** | 25.12.0 | `*-25.12.0` | x86 + armsr |
| **24.10** | 24.10.5 | `*-24.10.5` | x86 + armsr |
| **23.05** | 23.05.5 | `*-23.05.5` | x86 + armsr |
| **21.02** | 21.02.7 | `*-21.02.7` | x86 only (fw3 lab sign-off) |

| QEMU target | Script | Boot |
|-------------|--------|------|
| **x86** (default) | `run-openwrt-x86-qemu.sh` | KVM, ~1–2 min |
| **armsr** | `run-openwrt-armsr-armv8-qemu.sh` | TCG, ~15–30 min |

## Commands

```sh
# 1. Always run first
./scripts/validate-baseline.sh

# 2. Build ipk for every version (no QEMU)
./scripts/validate-openwrt-all.sh build

# 3. Full SDK matrix (versions × sdk-targets)
./scripts/validate-openwrt-all.sh build-full

# 4. Fast smoke: each version on x86 KVM (sequential — stops QEMU between runs)
./scripts/validate-openwrt-all.sh smoke-x86

# 5. Single cell
./scripts/validate-openwrt.sh --version 24.10
./scripts/validate-openwrt.sh --version 25.12 --qemu-target armsr
./scripts/validate-openwrt.sh --version 23.05 --skip-build   # ipk already built

# 6. List cells
./scripts/validate-openwrt-all.sh list
```

Back-compat: `./scripts/validate-openwrt-23.05.sh` → `validate-openwrt.sh --version 23.05`.

## What each smoke step checks

Via `qemu-smoke-fwlive.sh`:

- SSH, OpenWrt release, guest arch
- `ubus fwlive poll`, `ubus fwlive rules`, `ubus fwlive resolve`
- LuCI static JS + dispatcher (HTTP 403 login = OK)
- Optional nft ping log → parser pipeline

## Phased rollout (recommended)

| Phase | Command | When |
|-------|---------|------|
| A | `validate-baseline.sh` | Every PR / before publish |
| B | `validate-openwrt-all.sh build` | After feed/package changes |
| C | `validate-openwrt.sh --version 24.10` | Known-good reference cell |
| D | `validate-openwrt-all.sh smoke-x86` | Before release tag |
| E | `validate-openwrt.sh --version 24.10 --qemu-target armsr` | Production target sign-off |

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `OWRT_VALIDATE_VERSION` | `24.10` | Version key for `validate-openwrt.sh` |
| `OWRT_VALIDATE_QEMU_TARGET` | `x86` | `x86` or `armsr` |
| `OWRT_VALIDATE_SDK_TARGET` | `armsr-armv8` | SDK used to build ipk |
| `OWRT_VALIDATE_SSH_WAIT_X86` | `300` | SSH wait (seconds) |
| `OWRT_VALIDATE_SSH_WAIT_ARMSR` | `1800` | SSH wait for TCG |

## Related

- [`sdk-build-matrix.md`](sdk-build-matrix.md) — Docker SDK builds
- [`fwlive-acceptance.md`](fwlive-acceptance.md) — acceptance criteria
- [`openwrt-23.05-compat.md`](openwrt-23.05-compat.md) — 23.05 notes

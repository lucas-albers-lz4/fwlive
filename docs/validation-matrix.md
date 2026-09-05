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
| **25.12** | 25.12.5 | `*-25.12.5` | x86 + armsr |
| **24.10** | 24.10.8 | `*-24.10.8` | x86 + armsr |
| **23.05** | 23.05.5 | `*-23.05.5` | x86 + armsr |
| **22.03** | 22.03.7 | `x86-64-22.03.7` | x86 (SDK build); same `_all` ipk on armsr |
| **21.02** | 21.02.7 | `*-21.02.7` | x86 only (fw3 lab sign-off) |

| QEMU target | Script | Boot |
|-------------|--------|------|
| **x86** (default) | `run-openwrt-x86-qemu.sh` | KVM, ~1–2 min |
| **armsr** | `run-openwrt-armsr-armv8-qemu.sh` | TCG, ~15–30 min |

## Commands

```sh
# 1. Always run first
./scripts/validate-baseline.sh

# 2. Build (see sdk-build-matrix.md for full details)
./scripts/docker-sdk.sh build --target x86-64 --version 24.10

# 3. Fast smoke: each version on x86 KVM (sequential — stops QEMU between runs)
./scripts/validate-openwrt-all.sh smoke-x86

# 4. Single cell
./scripts/validate-openwrt.sh --version 24.10
./scripts/validate-openwrt.sh --version 25.12 --qemu-target armsr
./scripts/validate-openwrt.sh --version 23.05 --skip-build   # ipk already built

# 5. List cells
./scripts/validate-openwrt-all.sh list
```

Back-compat: `./scripts/validate-openwrt-23.05.sh` → `validate-openwrt.sh --version 23.05`. Same for `./scripts/validate-openwrt-22.03.sh`.

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

## Measured job times (Phase 5 / #276 + C2 / #240, 2026-09-05)

Merge-latency decisions rest on these numbers, not tribal estimates.
Cold = clean checkout through green; warm = smoke binary only.
QEMU C2 numbers are from a **pre-booted** 24.10.5 x86_64 guest
(`root@127.0.0.1:2222`, fwlive already installed).

| Job | Runner | Cold | Warm | Date |
|-----|--------|------|------|------|
| `test-view-mock` (Tier-2, required) | `ubuntu-latest` GH-hosted | ~25 s (`npm ci` ~1 s + Chromium install ~21 s + smoke ~3 s; job ~28 s end-to-end) | ~3 s (`npm run test:view`) | 2026-09-05, run 33940847911 |
| `test:view` local | x86_64 container, cached browsers | n/a (browsers pre-seeded) | ~2 s | 2026-09-05 |
| QEMU x86 Playwright lab bundle (`qemu-playwright-lab-smoke.sh`) | local x86 lab, guest already up | n/a (needs a booted guest + fwlive) | **32 s** (one Chromium; chip-invert + proto-ui + ui-reliability) | 2026-09-05 |
| QEMU x86 `qemu-smoke-fwlive.sh` | local x86 lab, guest already up | unmeasured (add KVM boot ~1–2 min per matrix above); next measurement: time `validate-openwrt.sh --version 24.10` from a stopped guest | **5 s** | 2026-09-05 |
| QEMU armsr full smoke | — | unmeasured (TCG boot ~15–30 min per matrix above); next measurement: when an armsr cell is next run on this host | — | no armsr guest this pass |

QEMU boot-inclusive and armsr rows stay unmeasured until those cells run.

## Flake history (`test-view-mock` since required)

30/30 green across the 30 most recent `fwlive-test.yml` runs
(2026-09-04 → 2026-09-05, incl. all Phase 1–4 wave branches). Zero
failures attributable to browser flake rather than real failure. Per
#240 §8: no revisit of required-now without numbers to the contrary.

## Playwright consolidation (Wave C2)

**Landed 2026-09-05.** Lab Playwright smokes share one Chromium context
via `tests/fwlive-lab-playwright-bundle.mjs` /
`scripts/qemu-playwright-lab-smoke.sh`. Sequence after one login:
chip-invert → proto-ui → ui-reliability. Individual
`tests/fwlive-*-smoke.mjs` and `scripts/qemu-*-smoke.sh` stay callable.
theme-tint stays separate (SSH theme switch + two sessions).
i18n-spotcheck stays separate (lang switch). Not on `fwlive-test.yml`.

The required path is unchanged: one Playwright file
(`tests/fwlive-view-smoke.mjs`) with one browser launch and one
in-process harness server (`scripts/serve-view-harness.mjs` on
localhost).

## Related

- [`sdk-build-matrix.md`](sdk-build-matrix.md) — Docker SDK builds
- [`fwlive-acceptance.md`](fwlive-acceptance.md) — acceptance criteria
- [`supported-releases.md`](supported-releases.md) — per-release lab notes (21.02 / 22.03 / 23.05)

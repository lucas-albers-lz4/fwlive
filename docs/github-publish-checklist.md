# Publish checklist (GitHub / GitLab)

Use before making this repo public upstream.

## Pre-flight

- [x] Replace `YOUR_ORG` in `openwrt-feed/luci-app-fwlive/Makefile` `PKG_MAINTAINER` URL → `lucas-albers-lz4`
- [ ] Review [LICENSE](../LICENSE) (Apache-2.0) and [ATTRIBUTION.md](../ATTRIBUTION.md) (OPNsense BSD 2-Clause)
- [ ] Run `./scripts/fwlive-test.sh`
- [ ] `./scripts/validate-baseline.sh`
- [ ] Optional QEMU: `./scripts/validate-openwrt.sh --version 24.10` — see [`validation-matrix.md`](validation-matrix.md)
- [ ] Review [`archive/README.md`](../archive/README.md) — nothing there should be required for new users

### Security (pre-release)

- [ ] rpcd `poll` line count capped server-side (`POLL_LINES_MAX=2000`) — [`rpcd/fwlive`](../openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive)
- [ ] rpcd JSON responses escape control characters (`json_escape` / `map_add`)
- [ ] `core/fwlive-log.js` tracked as a normal file (not a stale submodule gitlink)
- [ ] `node_modules/` not committed; dev deps declared in root `package.json`
- [ ] ACL scope understood: read-only firewall logs / rule hints / optional reverse DNS — grant `luci-app-fwlive` only to trusted admin LuCI users

## Distribution (canonical: A + C)

| Path | Audience | Doc |
|------|----------|-----|
| **GitHub Releases** — prebuilt `.ipk` / `.apk` | Router owners | [release.md](release.md), [user/installation.md](user/installation.md) |
| **`src-link`** to `openwrt-feed/` | Firmware / SDK builders | [feeds.conf.example](../feeds.conf.example) |

`src-git` to the main `fwlive` repo is **not supported** (feed root is `openwrt-feed/`, not repo root). A separate feed-only mirror would be needed for `src-git`; not required for v1.

## Repo contents

**Include:**

| Path | Purpose |
|------|---------|
| `openwrt-feed/` | Feed root (`luci-app-fwlive`) |
| `core/fwlive-log.js` | Parser source of truth + Node tests |
| `tests/`, `scripts/`, `docs/` | Tests, lab tooling, documentation |
| `feeds.conf.example` | Feed wiring template (`src-link`) |
| `README.md`, `docs/user/`, `docs/developer/`, `.gitignore`, `docker-compose.yml` | Entry points |
| `.github/workflows/fwlive-test.yml` | Parser CI on push/PR |

**Exclude** (already in `.gitignore` or should stay untracked):

- `node_modules/` (dev-only; install via `npm install` for screenshot capture)
- `lab/images/*.img`, SDK tarballs, `out/`, local `openwrt/` / `luci/` clones
- Full OPNsense `core` submodule (removed — we ship only `core/fwlive-log.js`)

## OpenWrt feed integration

This repo uses **`src-link`** to `openwrt-feed/` (see `feeds.conf.example`). That is the standard third-party feed pattern for a monorepo.

Alternatives (not primary):

- **LuCI tree fork** — copy `luci-app-fwlive/` into `luci/applications/` (see `openwrt-feed/README.md`).
- **`src-git` feed-only repo** — only if you later publish a mirror whose root *is* the feed.

## Package conventions (verified)

- `LUCI_PKGARCH:=all` — pure JS + shell rpcd, no target binaries
- `htdocs/` + `root/` layout per LuCI.mk
- `menu.d` JSON + `rpcd` ACL + `usr/libexec/rpcd/fwlive` (`list` / `call`)
- `LUCI_DEPENDS` on `luci-base`, `logd`, `rpcd`, `firewall4`
- No `po/` until i18n is requested

## macOS contributors

- Edit JS/docs and run `./scripts/fwlive-test.sh` locally
- **SDK builds and QEMU labs:** Linux x86_64 (VM, CI, or remote host)
- Unmaintained macOS QEMU: `archive/scripts/legacy/`

## After publish

1. Follow [release.md](release.md): tag `v0.1.0`, attach ipk/apk to GitHub Release
2. Confirm README install section points at Releases + `src-link`
3. Optional: submit to third-party OpenWrt feed index (outside this checklist)

## CI

Parser tests run on push/PR via `.github/workflows/fwlive-test.yml` (`./scripts/fwlive-test.sh`). No Docker/QEMU in CI.

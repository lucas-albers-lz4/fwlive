# Publish checklist (GitHub / GitLab)

Use before making this repo public upstream.

## Pre-flight

- [x] `PKG_MAINTAINER` set to `Lucas Albers <lucas.b.albers@gmail.com>` (Name \<email\> format for upstream)
- [ ] Review [LICENSE](../LICENSE) (Apache-2.0) and [ATTRIBUTION.md](../ATTRIBUTION.md) (OPNsense BSD 2-Clause)
- [ ] Run `./scripts/fwlive-test.sh`
- [ ] `./scripts/validate-baseline.sh`
- [ ] Optional QEMU: `./scripts/validate-openwrt.sh --version 24.10` — see [`validation-matrix.md`](validation-matrix.md)
- [ ] Confirm nothing in the removed `archive/` tree (deleted in #98) is required for new users — `rg -n "archive" .` should return no dead references

### Security (pre-release)

- [ ] rpcd `poll` line count capped server-side (`POLL_LINES_MAX=2000`) — [`rpcd/fwlive`](../openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive)
- [ ] rpcd JSON responses escape control characters (`json_escape` / `map_add`)
- [ ] `core/fwlive-log.js` tracked as a normal file (not a stale submodule gitlink)
- [ ] `node_modules/` not committed; dev deps declared in root `package.json`
- [ ] ACL scope understood: `luci-app-fwlive` grants read (`fwlive.rules|poll|resolve|logging_status`) and write (`enable_wan_logging`, `disable_wan_logging`) — **not** direct `ubus log.read` (poll reads logd as root inside rpcd). Grant only to trusted admin LuCI users

## Distribution (canonical)

| Path | Audience | Doc |
|------|----------|-----|
| **GitHub Pages feed** — signed opkg/apk | Router owners (`opkg install` / `apk add`) | [binary-feed.md](binary-feed.md) |
| **GitHub Releases** — prebuilt `.ipk` / `.apk` | Router owners (manual download) | [release.md](release.md), [user/installation.md](user/installation.md) |
| **`src-link`** to `openwrt-feed/` | Firmware / SDK builders | [feeds.conf.example](../feeds.conf.example) |

### External repo: `fwlive-packages`

- [x] Create public repo **`lucas-albers-lz4/fwlive-packages`** (GitHub Pages via `gh-pages`, written by CI)
- [x] Add deploy key → secret `FEED_DEPLOY_KEY` on **`fwlive`**
- [x] Generate usign + RSA keys → secrets `OPKG_FEED_*`, `APK_FEED_*` on **`fwlive`**
- [x] **Settings → Actions → General → Workflow permissions:** “Read and write permissions” (or rely on `contents: write` in `publish-packages.yml`)
- [x] See [binary-feed.md](binary-feed.md) for one-time setup
- [x] Add repo README — [`packages-repo/README.md`](../packages-repo/README.md) (copied to `gh-pages` by [`publish-packages.sh`](../scripts/publish-packages.sh))

`src-git` to the main `fwlive` repo is **not supported** (feed root is `openwrt-feed/`, not repo root). A separate feed-only **source** mirror would be needed for `src-git`; not required for v1 — see [Feed layout decision](developer/architecture.md#feed-layout-decision).

## Repo contents

**Include:**

| Path | Purpose |
|------|---------|
| `openwrt-feed/` | Feed root (`luci-app-fwlive`) |
| `core/fwlive-log.js` | Parser source of truth + Node tests |
| `tests/`, `scripts/`, `docs/` | Tests, lab tooling, documentation |
| `feeds.conf.example` | Feed wiring template (`src-link`) |
| `scripts/feeds.lock/` | Pinned OpenWrt feed commits (reproducible SDK builds) |
| `README.md`, `docs/user/`, `docs/developer/`, `.gitignore`, `docker-compose.yml` | Entry points |
| `.github/workflows/fwlive-test.yml` | Parser CI on push/PR |
| `.github/workflows/publish-packages.yml` | Release → build, feed deploy, QEMU smoke |

**Exclude** (already in `.gitignore` or should stay untracked):

- `node_modules/` (dev-only; install via `npm install` for screenshot capture)
- `lab/images/*.img`, SDK tarballs, `out/`, local `openwrt/` / `luci/` clones
- Full OPNsense `core` submodule (removed — we ship only `core/fwlive-log.js`)

## OpenWrt feed integration

This repo uses **`src-link`** to `openwrt-feed/` (see `feeds.conf.example`). That is the standard third-party feed pattern for a monorepo.

Alternatives (not primary):

- **LuCI tree fork** — copy `luci-app-fwlive/` into `luci/applications/` (see `openwrt-feed/README.md`).
- **`src-git` feed-only repo** — only if you later publish a mirror whose root *is* the feed.

### Upstream cut into `openwrt/luci`

When copying `openwrt-feed/luci-app-fwlive/` into `luci/applications/luci-app-fwlive/` for an upstream PR:

- [ ] Rewrite Makefile include: `include $(TOPDIR)/feeds/luci/luci.mk` → `include ../../luci.mk` (feed path stays as-is in this monorepo)
- [ ] Strip or rewrite package `README.md` links that point at monorepo `docs/` paths (dead after the copy)
- [ ] Confirm `po/templates/luci-app-fwlive.pot` is included
- [ ] State Apache-2.0 in the PR body (`PKG_LICENSE` is already set; no `PKG_LICENSE_FILES` needed to match peer LuCI apps)

## Package conventions (verified)

- `LUCI_PKGARCH:=all` — pure JS + shell rpcd, no target binaries
- `htdocs/` + `root/` layout per LuCI.mk
- `menu.d` JSON + `rpcd` ACL + `usr/libexec/rpcd/fwlive` (`list` / `call`)
- `LUCI_DEPENDS` on `luci-base`, `logd` (`rpcd` comes via `luci-base`; no hard `firewall4` dependency)
- `po/templates/luci-app-fwlive.pot` — i18n scaffolding (strings marked with `_()` in the view)

## macOS contributors

- Edit JS/docs and run `./scripts/fwlive-test.sh` locally
- **SDK builds and QEMU labs:** Linux x86_64 (VM, CI, or remote host)
- Unmaintained macOS QEMU: `archive/scripts/legacy/` *(removed in #98 — see git history)*

## After publish

1. Follow [release.md](release.md): publish GitHub Release → CI builds feed + attaches assets
2. Confirm [binary feed](binary-feed.md) URLs respond
3. Confirm README install section points at feed + Releases + `src-link`
4. Optional: submit to third-party OpenWrt feed index (outside this checklist)

## CI

| Workflow | When |
|----------|------|
| `fwlive-test.yml` | Every push/PR — parser tests |
| `publish-packages.yml` | Tag push `v*` — SDK build, reproducibility, Pages deploy, release assets, single-cell QEMU feed smoke (24.10 / TCG) |

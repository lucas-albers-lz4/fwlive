# Publish checklist (GitHub / GitLab)

Use before making this repo public upstream.

## Pre-flight

- [ ] Replace `YOUR_ORG` in `openwrt-feed/luci-app-fwlive/Makefile` `PKG_MAINTAINER` URL
- [ ] Review [LICENSE](../LICENSE) (Apache-2.0) and [ATTRIBUTION.md](../ATTRIBUTION.md) (OPNsense BSD 2-Clause)
- [ ] Run `./scripts/fwlive-test.sh`
- [ ] `./scripts/validate-baseline.sh`
- [ ] Optional QEMU: `./scripts/validate-openwrt.sh --version 24.10` — see [`validation-matrix.md`](validation-matrix.md)
- [ ] Review [`archive/README.md`](../archive/README.md) — nothing there should be required for new users

## Repo contents

**Include:**

| Path | Purpose |
|------|---------|
| `openwrt-feed/` | Feed root (`luci-app-fwlive`) |
| `core/fwlive-log.js` | Parser source of truth + Node tests |
| `tests/`, `scripts/`, `docs/` | Tests, lab tooling, documentation |
| `feeds.conf.example` | Feed wiring template |
| `README.md`, `docs/user/`, `docs/developer/`, `.gitignore`, `docker-compose.yml` | Entry points |

**Exclude** (already in `.gitignore` or should stay untracked):

- `lab/images/*.img`, SDK tarballs, `out/`, local `openwrt/` / `luci/` clones
- Full OPNsense `core` submodule (removed — we ship only `core/fwlive-log.js`)

## OpenWrt feed integration

This repo uses **`src-link`** to `openwrt-feed/` (see `feeds.conf.example`). That is the standard third-party feed pattern.

Alternatives:

- **`src-git`** to your public repo — OpenWrt expects packages at the **checkout root**. Either publish a feed-only repo whose root *is* `luci-app-fwlive`, or keep `src-link` / tarball.
- **LuCI tree fork** — copy `luci-app-fwlive/` into `luci/applications/` (see `openwrt-feed/README.md`).

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

1. Tag a release (e.g. `v0.1.0-mvp`) when the first public ipk is announced
2. Document install one-liner in README: SDK build + `opkg install` path
3. Optional: submit to third-party OpenWrt feed index (outside this checklist)

## CI suggestion (optional)

```yaml
# Minimal gate: parser tests only (no Docker/QEMU in CI)
- run: ./scripts/fwlive-test.sh
```

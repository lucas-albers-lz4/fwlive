# Release workflow

How maintainers publish **GitHub Releases** with prebuilt `luci-app-fwlive` packages. End users install from [Releases](https://github.com/lucas-albers-lz4/fwview/releases); builders use **`src-link`** — see [Installation](user/installation.md).

## Distribution model

- **Users:** download `.ipk` (23.05 / 24.10) or `.apk` (25.12+) from GitHub Releases.
- **Builders:** clone repo + `src-link` to `openwrt-feed/` — not `src-git` on this monorepo.

## Pre-flight

Run from the repo root on **Linux x86_64**:

```sh
./scripts/fwlive-test.sh
./scripts/validate-baseline.sh
```

Optional QEMU confidence: `./scripts/validate-openwrt.sh --version 24.10` — see [validation matrix](validation-matrix.md).

Full publish checklist: [github-publish-checklist.md](github-publish-checklist.md).

## Build release artifacts

`luci-app-fwlive` is **`_all`** — one package per OpenWrt **version** is enough (any SDK target produces the same `_all` artifact).

```sh
./scripts/docker-sdk.sh build --target x86-64 --version 23.05
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build --target x86-64 --version 25.12
```

Artifacts land under:

```
out/x86_64/23.05.5/fwview/luci-app-fwlive_*_all.ipk
out/x86_64/24.10.5/fwview/luci-app-fwlive_*_all.ipk
out/x86_64/25.12.0/fwview/luci-app-fwlive-*.apk
```

Verify filenames match `PKG_VERSION` in [`openwrt-feed/luci-app-fwlive/Makefile`](../openwrt-feed/luci-app-fwlive/Makefile).

## Tag

```sh
git tag -a v0.1.0 -m "Firewall Live View MVP — 23.05 / 24.10 / 25.12"
git push origin v0.1.0
```

Bump `PKG_VERSION` / `PKG_RELEASE` in the Makefile before tagging the next release.

## Create GitHub Release

1. Open **Releases → Draft a new release** on [github.com/lucas-albers-lz4/fwview](https://github.com/lucas-albers-lz4/fwview).
2. Choose tag `v0.1.0`.
3. Title: e.g. `v0.1.0 — Firewall Live View MVP`.
4. Attach the three built packages (rename in release notes if helpful, e.g. `luci-app-fwlive_0.1.0-1_24.10.5_all.ipk`).
5. Release notes — include:
   - Supported OpenWrt: **23.05**, **24.10**, **25.12**
   - Menu: **Status → Firewall Live View**
   - Requires firewall rules with **`log`** — [enabling firewall logs](user/enabling-firewall-logs.md)
   - Install one-liners (`opkg` / `apk`) from [installation.md](user/installation.md)

### Optional: `gh` CLI

```sh
gh release create v0.1.0 \
  --title "v0.1.0 — Firewall Live View MVP" \
  --notes-file docs/release-notes-v0.1.0.md \
  out/x86_64/23.05.5/fwview/luci-app-fwlive_*_all.ipk \
  out/x86_64/24.10.5/fwview/luci-app-fwlive_*_all.ipk \
  out/x86_64/25.12.0/fwview/luci-app-fwlive-*.apk
```

(Create `docs/release-notes-v0.1.0.md` ad hoc or paste notes inline with `--notes`.)

## After publish

- Confirm README [Install](../README.md#install) links work.
- Optional: announce on OpenWrt forums / third-party feed indexes (outside this repo).

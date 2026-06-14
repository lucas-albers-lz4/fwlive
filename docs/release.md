# Release workflow

How maintainers publish **GitHub Releases** and the **signed binary feed** on GitHub Pages. End users install from [Releases](https://github.com/lucas-albers-lz4/fwlive/releases) or the [opkg/apk feed](binary-feed.md); builders use **`src-link`** — see [Installation](user/installation.md).

## Distribution model

| Path | Audience |
|------|----------|
| **GitHub Releases** — `.ipk` / `.apk` attachments | Router owners (manual download) |
| **GitHub Pages feed** — [fwlive-packages](binary-feed.md) | Router owners (`opkg install` / `apk add`) |
| **`src-link`** to `openwrt-feed/` | Firmware / SDK builders |

## Pre-flight

Run from the repo root on **Linux x86_64**:

```sh
./scripts/fwlive-test.sh
./scripts/validate-baseline.sh
```

Optional QEMU confidence: `./scripts/validate-openwrt.sh --version 24.10` — see [validation matrix](validation-matrix.md).

Full publish checklist: [github-publish-checklist.md](github-publish-checklist.md).

## Release steps (automated CI)

1. Bump `PKG_VERSION` / `PKG_RELEASE` in [`openwrt-feed/luci-app-fwlive/Makefile`](../openwrt-feed/luci-app-fwlive/Makefile).
2. Update [`scripts/feeds.lock/`](../scripts/feeds.lock/) if the OpenWrt point release changed — see [binary-feed.md](binary-feed.md).
3. Merge to main.
4. Tag and push — **do not** create or publish a GitHub Release first; CI creates it with assets attached:

   ```sh
   git tag -a v0.1.0 -m "Firewall Live View — 23.05 / 24.10 / 25.12"
   git push origin v0.1.0
   ```

   Pushing the tag triggers [`.github/workflows/publish-packages.yml`](../.github/workflows/publish-packages.yml), which:
   - Builds packages for **23.05**, **24.10**, **25.12**
   - Verifies reproducible builds ([`verify-reproducible-build.sh`](../scripts/verify-reproducible-build.sh))
   - Signs and deploys the feed to **`lucas-albers-lz4/fwlive-packages`** (GitHub Pages)
   - Uploads release assets
   - Runs QEMU smoke tests installing from the live feed URL

   GitHub **immutable releases** cannot receive assets after publish. If you already published an empty release, delete it on GitHub (keep the tag) and re-run the workflow from Actions → **Run workflow**.

Ensure GitHub Actions secrets are configured — see [binary-feed.md](binary-feed.md).

## Manual build (local / fallback)

`luci-app-fwlive` is **`_all`** — one package per OpenWrt **version** is enough (any SDK target produces the same `_all` artifact).

```sh
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
./scripts/docker-sdk.sh build --target x86-64 --version 23.05
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build --target x86-64 --version 25.12
./scripts/verify-reproducible-build.sh
```

Artifacts:

```text
out/x86_64/23.05.5/fwlive/luci-app-fwlive_*_all.ipk
out/x86_64/24.10.5/fwlive/luci-app-fwlive_*_all.ipk
out/x86_64/25.12.0/fwlive/luci-app-fwlive-*.apk
```

Verify filenames match `PKG_VERSION` in the Makefile.

## Release notes template

Include in each release:

- Supported OpenWrt: **23.05**, **24.10**, **25.12**
- Feed install: [binary-feed.md](binary-feed.md)
- Menu: **Status → Firewall Live View**
- Requires firewall rules with **`log`** — [enabling firewall logs](user/enabling-firewall-logs.md)
- Manual install: [installation.md](user/installation.md)

## After publish

- Confirm README [Install](../README.md#install) links work.
- Confirm feed URLs respond: `./scripts/wait-feed-pages.sh https://lucas-albers-lz4.github.io/fwlive-packages`
- Optional: announce on OpenWrt forums / third-party feed indexes.

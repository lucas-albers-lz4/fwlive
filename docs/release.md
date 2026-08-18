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
Before cutting a `v*` tag, re-verify the `peaceiris/actions-gh-pages` SHA in
`publish-packages.yml` against the upstream tag (checklist pre-release item).

## Release steps (automated CI)

1. **Bump the third octet** of `PKG_VERSION` (keep `PKG_RELEASE:=1`) in
   [`openwrt-feed/luci-app-fwlive/Makefile`](../openwrt-feed/luci-app-fwlive/Makefile):
   `0.1.(N-1)` → `0.1.N` (e.g. `0.1.33` → `0.1.34`).
2. **Mirror `APP_VERSION`** in
   [`openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/constants.js`](../openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/constants.js)
   — it MUST equal `PKG_VERSION` (AGENTS.md lock).
3. **Fold the changelog**: move the `## [Unreleased]` entries into a new
   `## [v0.1.N] — YYYY-MM-DD` section at the top of [`CHANGELOG.md`](../CHANGELOG.md),
   grouped under `### Security` / `### Changed` / `### Added` / `### Fixed` with
   issue/PR references appended, and add the compare link at the bottom:
   `[v0.1.N]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.N-1...v0.1.N`.
4. Update [`scripts/feeds.lock/`](../scripts/feeds.lock/) if the OpenWrt point release changed — see [binary-feed.md](binary-feed.md).
5. Commit as a **direct `chore: release v0.1.N` commit on `master`** (release commits are not PRs) and push.
6. Create an annotated tag and push it — **do not** create or publish a GitHub Release first; CI creates it with assets attached:

   ```sh
   git tag -a v0.1.N -m "fwlive v0.1.N"
   git push origin v0.1.N
   ```

   Pushing the tag triggers [`.github/workflows/publish-packages.yml`](../.github/workflows/publish-packages.yml), which:
   - Builds packages for **21.02**, **22.03**, **23.05**, **24.10**, **25.12**
   - Verifies reproducible builds ([`verify-reproducible-build.sh`](../scripts/verify-reproducible-build.sh))
   - Signs and deploys the feed to **`lucas-albers-lz4/fwlive-packages`** (GitHub Pages)
   - Uploads release assets (one `.ipk` per opkg line, `.apk` for 25.12 — filenames include the OpenWrt line, e.g. `luci-app-fwlive_0.1.34_21.02_all.ipk`)
   - Runs a QEMU feed smoke (`smoke-from-feed` job) installing from the live feed URL — always on tag pushes (default cell **24.10**; `workflow_dispatch` can override via `feed_smoke` / `smoke_version` inputs)

   GitHub **immutable releases** cannot receive assets after publish. If you already published an empty release, delete it on GitHub (keep the tag) and re-run the workflow from Actions → **Run workflow**, entering the tag name.

Ensure GitHub Actions secrets are configured — see [binary-feed.md](binary-feed.md).

## Manual build (local / fallback)

`luci-app-fwlive` is **`_all`** — one package per OpenWrt **version** is enough (any SDK target produces the same `_all` artifact).

```sh
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
./scripts/docker-sdk.sh build --target x86-64 --version 21.02
./scripts/docker-sdk.sh build --target x86-64 --version 22.03
./scripts/docker-sdk.sh build --target x86-64 --version 23.05
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build --target x86-64 --version 25.12
./scripts/verify-reproducible-build.sh
```

Artifacts:

```text
out/x86_64/21.02.7/fwlive/luci-app-fwlive_*_all.ipk
out/x86_64/22.03.7/fwlive/luci-app-fwlive_*_all.ipk
out/x86_64/23.05.5/fwlive/luci-app-fwlive_*_all.ipk
out/x86_64/24.10.8/fwlive/luci-app-fwlive_*_all.ipk
out/x86_64/25.12.5/fwlive/luci-app-fwlive-*.apk
```

GitHub Release attachments are renamed with the OpenWrt line suffix (e.g. `_21.02_all.ipk`) so multiple `_all.ipk` builds do not collide on upload.

Verify filenames match `PKG_VERSION` in the Makefile.

## Release notes template

Include in each release:

- Supported OpenWrt: **21.02**, **22.03**, **23.05**, **24.10** (opkg) · **25.12** (apk)
- Feed install: [binary-feed.md](binary-feed.md)
- Menu: **Status → Firewall Live View**
- Requires firewall rules with **`log`** — [enabling firewall logs](user/enabling-firewall-logs.md)
- Manual install: [installation.md](user/installation.md)

## After publish

- Confirm README [Install](../README.md#install) links work.
- Confirm feed URLs respond: `./scripts/wait-feed-pages.sh https://lucas-albers-lz4.github.io/fwlive-packages`
- Optional: announce on OpenWrt forums / third-party feed indexes.

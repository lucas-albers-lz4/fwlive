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

For upstream/release sign-off, require fresh source extraction by setting
`FWLIVE_I18N_REQUIRE_SCAN=1` and provide the OpenWrt scanner with
`FWLIVE_I18N_SCAN=/path/to/luci/build/i18n-scan.pl` when it is not on `PATH`.
Missing scanner prerequisites then fail the sign-off run instead of being
treated as a passing skip.

Before creating the release tag, run `./scripts/formal-tlc.sh` on the release
commit. The models and pinned runner are repeatable locally; Actions provides a
manual-only **formal TLC** workflow for rerunning the same check on a selected
ref. This keeps TLC out of the normal push and pull-request CI path.

Optional QEMU confidence: `./scripts/validate-openwrt.sh --version 24.10` — see [validation matrix](validation-matrix.md).

Full publish checklist: [github-publish-checklist.md](github-publish-checklist.md).
Before cutting a `v*` tag, make sure that the `peaceiris/actions-gh-pages` SHA in
`publish-packages.yml` still matches the upstream tag (checklist pre-release item).

## Release steps (automated CI)

1. **Bump the third octet** of `PKG_VERSION` (keep `PKG_RELEASE:=1`) in
   [`openwrt-feed/luci-app-fwlive/Makefile`](../openwrt-feed/luci-app-fwlive/Makefile):
   from the current released third octet to the next unused number
   (e.g. `0.1.33` → `0.1.34`; after a skipped number, `0.1.19` → `0.1.21`).
2. **Mirror `APP_VERSION`** in
   [`openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/constants.js`](../openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/constants.js)
   — it MUST equal `PKG_VERSION` (AGENTS.md lock).
3. **Audit and fold the changelog**: before moving the `## [Unreleased]` entries
   into a new version section, audit the exact range since the previous released
   tag with `git log --oneline <previous-released-tag>..HEAD` and inspect the
   changes in each merged PR and direct commit. Match every notable user-visible
   change in that range to an entry, following [the per-PR changelog rule](developer/contributing.md#changelog-entries);
   the PR-only release-note generator can miss direct commits. Test-only,
   tooling, and internal refactors may be omitted unless they change a user or
   maintainer workflow. Group related changes by outcome and append issue/PR
   references. Create a new `## [v0.1.N] — YYYY-MM-DD` section at the top of
   [`CHANGELOG.md`](../CHANGELOG.md), grouped under `### Security` / `### Changed`
   / `### Added` / `### Fixed`, and add the compare link at the bottom to the
   previous **released** tag (not `N-1` if that number was skipped):
   `[v0.1.N]: https://github.com/lucas-albers-lz4/fwlive/compare/<previous-released-tag>...v0.1.N`.
   Example: `v0.1.21` compares to `v0.1.19` because **v0.1.20 was never tagged**.
4. Update [`scripts/feeds.lock/`](../scripts/feeds.lock/) if the OpenWrt point release changed — see [binary-feed.md](binary-feed.md).
5. Commit as a **direct `chore: release v0.1.N` commit on `master`** (release commits are not PRs) and push.
6. Create an annotated tag and push it — **do not** create or publish a GitHub Release first; CI creates it with assets attached:

   ```sh
   git tag -a v0.1.N -m "fwlive v0.1.N"
   git push origin v0.1.N
   ```

   Pushing the tag triggers [`.github/workflows/publish-packages.yml`](../.github/workflows/publish-packages.yml), which:
   - Builds packages for **23.05**, **24.10**, **25.12**
   - Checks reproducible builds ([`verify-reproducible-build.sh`](../scripts/verify-reproducible-build.sh))
   - Signs and deploys the feed to **`lucas-albers-lz4/fwlive-packages`** (GitHub Pages)
   - Uploads release assets (one `.ipk` per opkg line, `.apk` for 25.12 — filenames include the OpenWrt line, e.g. `luci-app-fwlive_0.1.34_23.05_all.ipk`)
   - Runs a QEMU feed smoke (`smoke-from-feed` job) installing from the live feed URL on tag pushes and `workflow_dispatch` (default cell **24.10**; `feed_smoke` / `smoke_version` inputs)

   GitHub **immutable releases** cannot receive assets after publish. If you already published an empty release, delete it on GitHub (keep the tag) and re-run the workflow from Actions → **Run workflow**, entering the tag name.

Make sure that the GitHub Actions secrets are configured — see [binary-feed.md](binary-feed.md).

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
out/x86_64/24.10.8/fwlive/luci-app-fwlive_*_all.ipk
out/x86_64/25.12.5/fwlive/luci-app-fwlive-*.apk
```

GitHub Release attachments are renamed with the OpenWrt line suffix (e.g. `_23.05_all.ipk`) so multiple `_all.ipk` builds do not collide on upload.

Make sure that the filenames match `PKG_VERSION` in the Makefile.

## Release notes template

The publish workflow generates the GitHub Release **body from the matching
`## [vX.Y.Z]` section of CHANGELOG.md** (`feed_publish_release_notes_file`) —
not from GitHub's `--generate-notes`, which enumerates only merged PRs in the
tag range and ships a near-empty body when the range holds direct commits
(v0.1.40 shipped with just the compare link). Consequences for the cut:

- **The CHANGELOG fold for the version is required before tagging** — if the
  section is missing, the workflow falls back to `--generate-notes` with a
  warning, which is exactly the empty-body behavior we removed.
- Keep each folded section readable standalone on the release page: it is
  copied verbatim; the workflow appends the feed-install footer and the
  previous-tag compare link.
- Describe behavior as it existed at the tagged release; record later changes
  in the release where they landed. For example, v0.1.47 shipped the GNU
  timeout-helper contract, while v0.1.48 removed that dependency and wrapper
  (#1053 / PR #1054). Keep both version histories accurate.

Include in each release (CHANGELOG section content):

- Supported OpenWrt: **23.05**, **24.10** (opkg) · **25.12** (apk)
- Feed install: [binary-feed.md](binary-feed.md)
- Menu: **Status → Firewall Live View**
- Requires firewall rules with **`log`** — [enabling firewall logs](user/enabling-firewall-logs.md)
- Manual install: [installation.md](user/installation.md)

## After publish

- Make sure that the README [Install](../README.md#install) links work.
- Feed URL reachability: CI already runs `./scripts/wait-feed-pages.sh` in
  `smoke-from-feed`. Run it locally only for a `workflow_dispatch` with
  `feed_smoke=false`, or when debugging Pages outside CI.
- Optional: announce on OpenWrt forums / third-party feed indexes.

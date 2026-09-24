# Binary package feed (GitHub Pages)

Signed **opkg** / **apk** feed for installing `luci-app-fwlive` with `opkg install` or `apk add` — hosted on GitHub Pages at:

**https://lucas-albers-lz4.github.io/fwlive-packages/**

Manual `.ipk` / `.apk` downloads remain on [GitHub Releases](https://github.com/lucas-albers-lz4/fwlive/releases). See [Installation](user/installation.md).

---

## Feed layout

```text
fwlive-packages/          (gh-pages branch)
  README.md               repo landing page (from packages-repo/ in fwlive)
  public.key              opkg trust anchor
  fwlive-feed.rsa.pub     apk trust anchor
  manifest.json           release metadata + sha256
  23.05/
    luci-app-fwlive_*_all.ipk
    Packages  Packages.gz  Packages.sig
  24.10/
    … (same as 23.05)
  25.12/
    all/
      luci-app-fwlive-*.apk
      packages.adb
```

The package is **`_all`** — one feed URL per OpenWrt release line, not per CPU architecture.

---

## Release manifest

`manifest.json` records release metadata plus one entry per published cell
(**target × OpenWrt line**). The SDK images referenced by the build are
**mutable tags** (`ghcr.io/openwrt/sdk:x86-64-23.05.5`), so each cell also
records the **immutable digest** of the image it was actually built from —
making a release attributable to the exact image despite the moving tag.

```json
{
  "git_tag": "v0.1.16",
  "packages": [
    {
      "openwrt": "23.05",
      "file": "luci-app-fwlive_0.1.16_23.05_all.ipk",
      "sha256": "…",
      "sdk_image": "ghcr.io/openwrt/sdk:x86-64-23.05.5",
      "sdk_digest": "ghcr.io/openwrt/sdk@sha256:…",
      "feeds_lock_sha256": "…",
      "feeds": {
        "base": "…",
        "packages": "…",
        "luci": "…"
      }
    },
    …
  ]
}
```

Each cell records the package hash, the SDK image and digest, the feeds lock
hash, and the `base` / `packages` / `luci` commits from that lock. Those SHAs
are the pins `feeds_lock_assert_heads` checks when the SDK volume is set up
or reused; manifest generation copies the lock pins rather than re-running
`rev-parse` at publish time. A host-signed opkg cell (`feeds_ready` exit 1)
therefore records **declared** pins, not HEADs observed in that job.
`feeds_lock_assert_heads` treats untracked files as a dirty tree — an extra
Makefile under a feed checkout is visible to `feeds install`.

### Digest source

After the SDK image is pulled, the digest is resolved per cell with:

```sh
docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
	ghcr.io/openwrt/sdk:x86-64-23.05.5 \
	| awk -v r='ghcr.io/openwrt/sdk' 'index($0, r "@sha256:") == 1 { print; exit }'
# → ghcr.io/openwrt/sdk@sha256:…
```

The selected entry is the `RepoDigest` whose repository prefix matches the image
that was actually pulled and built against; list position is not trusted. This
is implemented in `scripts/lib/sdk-matrix.sh` → `sdk_matrix_image_digest`.

### Fallback

If no matching `RepoDigest` is available (for example, a locally built or
registry-less image), the image ID is recorded as `@sha256:<image ID>` and a
**warning** is emitted to stderr — an empty digest is **never** recorded
silently. If neither the matching `RepoDigest` nor the image ID can be read,
manifest generation **fails** (no silent empty value).

### Out of scope

`ghcr.io/openwrt/rootfs:x86-64` is **not** recorded: it is
docker-compose-experimental only and is never pulled by the release workflow.

---

## User install

For install commands, see the [Installation guide](user/installation.md). This file is the feed and CI reference.

---

## Lab: install from feed URL

```sh
FWLIVE_FEED_BASE_URL=https://lucas-albers-lz4.github.io/fwlive-packages \
  ./scripts/validate-feed-smoke.sh --version 24.10
```

---

# Maintainer: one-time repo setup

## 1. Create `fwlive-packages`

1. Create empty GitHub repo **`lucas-albers-lz4/fwlive-packages`** (public).
2. **Settings → Pages → Build and deployment:** source = **`gh-pages`** branch (CI writes this branch; no manual Pages source needed after first deploy).

## 2. Deploy key

On **`fwlive-packages`**: Settings → Deploy keys → Add deploy key (read/write), note the private key.

On **`fwlive`**: Settings → Secrets → Actions:

| Secret | Value |
|--------|-------|
| `FEED_DEPLOY_KEY` | Private deploy key for `fwlive-packages` |
| `OPKG_FEED_SECRET_KEY` | Full contents of usign secret key file |
| `OPKG_FEED_PUBLIC_KEY` | Full contents of `public.key` |
| `APK_FEED_SECRET_KEY` | Full contents of RSA private key (`apk-secret.rsa`) |
| `APK_FEED_PUBLIC_KEY` | Full contents of `fwlive-feed.rsa.pub` |

## 3. Generate signing keys (once, offline)

```sh
# opkg (usign)
usign -G -s opkg-secret.key -p public.key -c "fwlive opkg feed"

# apk (RSA for apk mkndx --sign)
openssl genrsa -out apk-secret.rsa 4096
openssl rsa -in apk-secret.rsa -pubout -out fwlive-feed.rsa.pub
```

Store **private** keys only in GitHub Actions secrets. Never commit them to either repo.

### Common mistakes

- `OPKG_FEED_SECRET_KEY` must be the **usign** secret from `usign -G` (two lines: `untrusted comment:` + `RW…` base64). The **openssl RSA** key is only for `APK_FEED_SECRET_KEY`.
- Pasting the secret into GitHub as **one line** (no newline between comment and key) makes usign fail with **`Premature end of file`**. Either paste the file verbatim with its line break, or store **`base64 -w0 opkg-secret.key`** in the secret (CI auto-decodes).

Make sure that the signing keys work locally before you update the GitHub secrets:

```sh
OPKG_FEED_SECRET_KEY=./opkg-secret.key OPKG_FEED_PUBLIC_KEY=./public.key \
APK_FEED_SECRET_KEY=./apk-secret.rsa APK_FEED_PUBLIC_KEY=./fwlive-feed.rsa.pub \
  ./scripts/validate-feed-keys.sh
```

Expected usign secret shape:

```text
untrusted comment: fwlive opkg feed
RWRCSwAAAAD…base64…=
```

Expected apk secret shape: PEM `-----BEGIN PRIVATE KEY-----` (openssl genrsa output).

---

## Automated publish (CI)

On **tag push** (`v*`) or manual workflow dispatch, [`.github/workflows/publish-packages.yml`](../.github/workflows/publish-packages.yml):

1. Checks the signing keys via [`validate-feed-keys.sh`](../scripts/validate-feed-keys.sh) (before build).
2. Builds `luci-app-fwlive` for **23.05**, **24.10**, **25.12** (Docker SDK, pinned feeds).
3. Runs [`verify-reproducible-build.sh`](../scripts/verify-reproducible-build.sh) (double-build sha256 gate).
4. Stages signed feed via [`publish-packages.sh`](../scripts/publish-packages.sh).
5. Guards against a live-feed downgrade ([`guard-feed-deploy.sh`](../scripts/guard-feed-deploy.sh); HTTP 404 skips for bootstrap).
6. Deploys to **`fwlive-packages`** `gh-pages`.
7. Uploads `.ipk` / `.apk` to the GitHub Release.
8. Boots one QEMU x86 reference guest (**24.10** by default) and installs from the **live Pages URL** ([`validate-feed-smoke.sh`](../scripts/validate-feed-smoke.sh); TCG on hosted runners — [#10](https://github.com/lucas-albers-lz4/fwlive/issues/10)).

### Downgrade guard (#590)

Before Pages deploy, `build-publish` fetches the live `manifest.json`
(cache-bust `?cb=${GITHUB_RUN_ID}`, `Cache-Control: no-cache`) and runs
`guard-feed-deploy.sh`. A newer or equal `git_tag` proceeds; an older tag
is rejected unless workflow_dispatch `allow_rollback=true`.

HTTP 404 (no live `manifest.json` yet — first publish or wiped `gh-pages`)
prints a warning and **skips** the guard. Any other non-200 or curl
failure fails the job.

Guard, Deploy, and Upload GitHub Release assets are **sequential steps in
the same `build-publish` job** (not split jobs). A rejected or failed
downgrade guard aborts that job, so GitHub Release assets are **not**
uploaded for that run. Bootstrap 404 skips the guard only; it does not
skip the rest of the job.

---

## Manual publish (fallback)

```sh
# Build
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
./scripts/docker-sdk.sh build --target x86-64 --version 23.05
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build --target x86-64 --version 25.12
./scripts/verify-reproducible-build.sh

# Stage (signing keys via env)
OPKG_FEED_SECRET_KEY=./opkg-secret.key OPKG_FEED_PUBLIC_KEY=./public.key \
APK_FEED_SECRET_KEY=./apk-secret.rsa APK_FEED_PUBLIC_KEY=./fwlive-feed.rsa.pub \
  ./scripts/publish-packages.sh feed-staging

# Push feed-staging/ to fwlive-packages gh-pages (or open PR)
```

---

## Reproducible builds

Pinned inputs (regenerate when bumping OpenWrt point releases):

| Input | Location |
|-------|----------|
| Feed commits | [`scripts/feeds.lock/`](../scripts/feeds.lock/) per SDK version (GitHub mirrors of git.openwrt.org; every `src-git` line is a peeled `^<40-hex>` commit, including 23.05 `base`) |
| SDK image tag | [`scripts/lib/sdk-matrix.sh`](../scripts/lib/sdk-matrix.sh) |
| SDK image digest | Recorded per cell in `manifest.json` ([release manifest](#release-manifest)) |
| Feed revisions | Same manifest: lock pins for `feeds.base` / `feeds.packages` / `feeds.luci` plus `feeds_lock_sha256` |
| Package version | `PKG_VERSION` / `PKG_RELEASE` in package Makefile |
| Timestamps | `SOURCE_DATE_EPOCH` (git commit epoch; set in CI on release tag) |

`verify-reproducible-build.sh` is unchanged — it still proves input
determinism; the recorded `sdk_digest` makes each release attributable to the
exact SDK image it was built from.

Publish CI (`publish-packages`) retries `feeds update` (3× + wipe partial clones +
HTTP/1.1) and bind-mounts host `.ci-sdk-cache/{dl,feeds/<version>}` into `/builder`.
Actions caches those dirs with an exact `feeds.lock` hash key (no `restore-keys`) so
a lock change never restores a stale tree. Note: GHA caches are **ref-scoped** — tag
publishes do not warm-hit across tags; the bind mounts still speed local rebuilds and
same-ref re-runs. A lock stamp under feeds forces refresh when pins change.

Make sure that the build is reproducible:

```sh
./scripts/verify-reproducible-build.sh
```

### Refresh feed lock files

When OpenWrt bumps a point release (e.g. 24.10.7 → 24.10.8):

```sh
docker run --rm ghcr.io/openwrt/sdk:x86-64-24.10.8 cat feeds.conf.default
# Copy into scripts/feeds.lock/24.10.8/feeds.conf (add src-link fwlive line).
# Replace any `;branch` src-git ref with the peeled 40-hex commit
# (`git ls-remote … 'refs/tags/vX.Y.Z^{}'`). `tests/feeds-lock-pins.test.sh`
# rejects unpinned src-git lines.
# Update sdk_matrix_version_patch in sdk-matrix.sh
```

---

## Related

- [Release workflow](release.md)
- [Publish checklist](github-publish-checklist.md)
- [SDK build matrix](sdk-build-matrix.md)

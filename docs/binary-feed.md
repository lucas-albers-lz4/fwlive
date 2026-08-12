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
  21.02/
    luci-app-fwlive_*_all.ipk
    Packages  Packages.gz  Packages.sig
  22.03/
    luci-app-fwlive_*_all.ipk
    Packages  Packages.gz  Packages.sig
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
**mutable tags** (`ghcr.io/openwrt/sdk:x86-64-21.02.7`), so each cell also
records the **immutable digest** of the image it was actually built from —
making a release attributable to the exact image despite the moving tag.

```json
{
  "git_tag": "v0.1.16",
  "packages": [
    {
      "openwrt": "21.02",
      "file": "luci-app-fwlive_0.1.16_21.02_all.ipk",
      "sha256": "…",
      "sdk_image": "ghcr.io/openwrt/sdk:x86-64-21.02.7",
      "sdk_digest": "ghcr.io/openwrt/sdk@sha256:…"
    },
    …
  ]
}
```

Before this change a cell was `{"openwrt", "file", "sha256"}` only; the
`sdk_image` / `sdk_digest` pair is added alongside the per-package sha256.

### Digest source

After the SDK image is pulled, the digest is resolved per cell with:

```sh
docker image inspect --format '{{index .RepoDigests 0}}' ghcr.io/openwrt/sdk:x86-64-21.02.7
# → ghcr.io/openwrt/sdk@sha256:…
```

`RepoDigests[0]` is the registry digest of the image that was actually pulled
and built against (implemented in `scripts/lib/sdk-matrix.sh` → `sdk_matrix_image_digest`).

### Fallback

If `RepoDigests` is **empty** (locally built / registry-less image), the image
ID is recorded as `@sha256:<image ID>` and a **warning** is emitted to stderr —
an empty digest is **never** recorded silently. If neither `RepoDigests` nor
the image ID can be read, manifest generation **fails** (no silent empty value).

### Out of scope

`ghcr.io/openwrt/rootfs:x86-64` is **not** recorded: it is
docker-compose-experimental only and is never pulled by the release workflow.

---

## User install

### OpenWrt 21.02.x (opkg, legacy fw3)

OpenWrt **21.02 is EOL** — use only if you are stuck on fw3/iptables. Install the **21.02-built** package from this feed (not 23.05+).

```sh
wget -O /tmp/fwlive.key https://lucas-albers-lz4.github.io/fwlive-packages/public.key
opkg-key add /tmp/fwlive.key
echo 'src/gz fwlive https://lucas-albers-lz4.github.io/fwlive-packages/21.02' >> /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-fwlive
```

See [21.02 compat](openwrt-21.02-compat.md).

### OpenWrt 22.03.x (opkg, EOL)

OpenWrt **22.03 is EOL** — use only if you cannot upgrade to 23.05+ yet.

```sh
wget -O /tmp/fwlive.key https://lucas-albers-lz4.github.io/fwlive-packages/public.key
opkg-key add /tmp/fwlive.key
echo 'src/gz fwlive https://lucas-albers-lz4.github.io/fwlive-packages/22.03' >> /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-fwlive
```

See [22.03 compat](openwrt-22.03-compat.md).

### OpenWrt 23.05 / 24.10 (opkg)

```sh
wget -O /tmp/fwlive.key https://lucas-albers-lz4.github.io/fwlive-packages/public.key
opkg-key add /tmp/fwlive.key
echo 'src/gz fwlive https://lucas-albers-lz4.github.io/fwlive-packages/24.10' >> /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-fwlive
```

Use `…/23.05` for OpenWrt 23.05.

### OpenWrt 25.12+ (apk)

```sh
wget -O /tmp/fwlive-feed.rsa.pub https://lucas-albers-lz4.github.io/fwlive-packages/fwlive-feed.rsa.pub
mkdir -p /etc/apk/keys
cp /tmp/fwlive-feed.rsa.pub /etc/apk/keys/fwlive-feed.rsa.pub
echo 'https://lucas-albers-lz4.github.io/fwlive-packages/25.12/all/packages.adb' \
  >> /etc/apk/repositories.d/fwlive.list
apk update
apk add luci-app-fwlive
```

Menu: **Status → Firewall Live View**.

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

Verify locally before updating GitHub secrets:

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

1. Validates signing keys via [`validate-feed-keys.sh`](../scripts/validate-feed-keys.sh) (before build).
2. Builds `luci-app-fwlive` for **21.02**, **22.03**, **23.05**, **24.10**, **25.12** (Docker SDK, pinned feeds).
3. Runs [`verify-reproducible-build.sh`](../scripts/verify-reproducible-build.sh) (double-build sha256 gate).
4. Stages signed feed via [`publish-packages.sh`](../scripts/publish-packages.sh).
5. Deploys to **`fwlive-packages`** `gh-pages`.
6. Uploads `.ipk` / `.apk` to the GitHub Release.
7. Boots one QEMU x86 reference guest (**24.10** by default) and installs from the **live Pages URL** ([`validate-feed-smoke.sh`](../scripts/validate-feed-smoke.sh); TCG on hosted runners — [#10](https://github.com/lucas-albers-lz4/fwlive/issues/10)).

---

## Manual publish (fallback)

```sh
# Build
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
./scripts/docker-sdk.sh build --target x86-64 --version 21.02
./scripts/docker-sdk.sh build --target x86-64 --version 22.03
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
| Feed commits | [`scripts/feeds.lock/`](../scripts/feeds.lock/) per SDK version (GitHub mirrors of git.openwrt.org; pinned SHAs unchanged) |
| SDK image tag | [`scripts/lib/sdk-matrix.sh`](../scripts/lib/sdk-matrix.sh) |
| SDK image digest | Recorded per cell in `manifest.json` ([release manifest](#release-manifest)) |
| Package version | `PKG_VERSION` / `PKG_RELEASE` in package Makefile |
| Timestamps | `SOURCE_DATE_EPOCH` (git commit epoch; set in CI on release tag) |

`verify-reproducible-build.sh` is unchanged — it still proves input
determinism; the recorded `sdk_digest` makes each release attributable to the
exact SDK image it was built from.

Publish CI (`publish-packages`) retries `feeds update` (3× + HTTP/1.1) and caches
`/builder/feeds` + `/builder/dl` across runs (`scripts/ci-cache-sdk-feeds.sh`,
keyed on the feeds.lock tree) so a transient TLS drop does not fail a release.

Verify locally:

```sh
./scripts/verify-reproducible-build.sh
```

### Refresh feed lock files

When OpenWrt bumps a point release (e.g. 24.10.8 → 24.10.6):

```sh
docker run --rm ghcr.io/openwrt/sdk:x86-64-24.10.6 cat feeds.conf.default
# Copy into scripts/feeds.lock/24.10.6/feeds.conf (add src-link fwlive line)
# Update sdk_matrix_version_patch in sdk-matrix.sh
```

---

## Related

- [Release workflow](release.md)
- [Publish checklist](github-publish-checklist.md)
- [SDK build matrix](sdk-build-matrix.md)

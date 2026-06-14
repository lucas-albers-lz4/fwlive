# Binary package feed (GitHub Pages)

Signed **opkg** / **apk** feed for installing `luci-app-fwlive` with `opkg install` or `apk add` — hosted on GitHub Pages at:

**https://lucas-albers-lz4.github.io/fwlive-packages/**

Manual `.ipk` / `.apk` downloads remain on [GitHub Releases](https://github.com/lucas-albers-lz4/fwlive/releases). See [Installation](user/installation.md).

## Feed layout

```text
fwlive-packages/          (gh-pages branch)
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

## User install

### OpenWrt 24.10 (opkg)

```sh
wget -O /tmp/fwlive.key https://lucas-albers-lz4.github.io/fwlive-packages/public.key
opkg-key add /tmp/fwlive.key
echo 'src/gz fwlive https://lucas-albers-lz4.github.io/fwlive-packages/24.10' >> /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-fwlive
```

### OpenWrt 23.05 (opkg)

Same as 24.10; use feed URL `…/fwlive-packages/23.05`.

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

## One-time repo setup (maintainers)

### 1. Create `fwlive-packages`

1. Create empty GitHub repo **`lucas-albers-lz4/fwlive-packages`** (public).
2. **Settings → Pages → Build and deployment:** source = **`gh-pages`** branch (CI writes this branch; no manual Pages source needed after first deploy).

### 2. Deploy key

On **`fwlive-packages`**: Settings → Deploy keys → Add deploy key (read/write), note the private key.

On **`fwlive`**: Settings → Secrets → Actions:

| Secret | Value |
|--------|--------|
| `FEED_DEPLOY_KEY` | Private deploy key for `fwlive-packages` |
| `OPKG_FEED_SECRET_KEY` | Full contents of usign secret key file |
| `OPKG_FEED_PUBLIC_KEY` | Full contents of `public.key` |
| `APK_FEED_SECRET_KEY` | Full contents of RSA private key (`apk-secret.rsa`) |
| `APK_FEED_PUBLIC_KEY` | Full contents of `fwlive-feed.rsa.pub` |

### 3. Generate signing keys (once, offline)

```sh
# opkg (usign)
usign -G -s opkg-secret.key -p public.key -c "fwlive opkg feed"

# apk (RSA for apk mkndx --sign)
openssl genrsa -out apk-secret.rsa 4096
openssl rsa -in apk-secret.rsa -pubout -out fwlive-feed.rsa.pub
```

Store **private** keys only in GitHub Actions secrets. Never commit them to either repo.

**Common mistakes**

- `OPKG_FEED_SECRET_KEY` must be the **usign** secret from `usign -G` (two lines: `untrusted comment:` + `RW…` base64). The **openssl RSA** key is only for `APK_FEED_SECRET_KEY`.
- Pasting the secret into GitHub as **one line** (no newline between comment and key) makes usign fail with **`Premature end of file`**. Either paste the file verbatim with its line break, or store **`base64 -w0 opkg-secret.key`** in the secret (CI auto-decodes).

Verify locally before updating GitHub secrets:

```sh
OPKG_FEED_SECRET_KEY=./opkg-secret.key OPKG_FEED_PUBLIC_KEY=./public.key \
APK_FEED_SECRET_KEY=./apk-secret.rsa APK_FEED_PUBLIC_KEY=./fwlive-feed.rsa.pub \
  ./scripts/validate-feed-keys.sh
```

No package build required. CI runs this immediately after writing keys from GitHub secrets (before the ~30 minute SDK build).

Expected usign secret shape:

```text
untrusted comment: fwlive opkg feed
RWRCSwAAAAD…base64…=
```

Expected apk secret shape: PEM `-----BEGIN PRIVATE KEY-----` (openssl genrsa output).

## Automated publish (CI)

On **GitHub Release publish**, [`.github/workflows/publish-packages.yml`](../.github/workflows/publish-packages.yml):

1. Validates signing keys via [`validate-feed-keys.sh`](../scripts/validate-feed-keys.sh) (before build).
2. Builds `luci-app-fwlive` for **23.05**, **24.10**, **25.12** (Docker SDK, pinned feeds).
3. Runs [`verify-reproducible-build.sh`](../scripts/verify-reproducible-build.sh) (double-build sha256 gate).
4. Stages signed feed via [`publish-packages.sh`](../scripts/publish-packages.sh).
5. Deploys to **`fwlive-packages`** `gh-pages`.
6. Uploads `.ipk` / `.apk` to the GitHub Release.
7. Boots QEMU x86 guests and installs from the **live Pages URL** ([`validate-feed-smoke.sh`](../scripts/validate-feed-smoke.sh)).

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

## Reproducible builds

Pinned inputs (regenerate when bumping OpenWrt point releases):

| Input | Location |
|-------|----------|
| Feed commits | [`scripts/feeds.lock/`](../scripts/feeds.lock/) per SDK version |
| SDK image tag | [`scripts/lib/sdk-matrix.sh`](../scripts/lib/sdk-matrix.sh) |
| Package version | `PKG_VERSION` / `PKG_RELEASE` in package Makefile |
| Timestamps | `SOURCE_DATE_EPOCH` (git commit epoch; set in CI on release tag) |

Verify locally:

```sh
./scripts/verify-reproducible-build.sh
```

### Refresh feed lock files

When OpenWrt bumps a point release (e.g. 24.10.5 → 24.10.6):

```sh
docker run --rm ghcr.io/openwrt/sdk:x86-64-24.10.6 cat feeds.conf.default
# Copy into scripts/feeds.lock/24.10.6/feeds.conf (add src-link fwlive line)
# Update sdk_matrix_version_patch in sdk-matrix.sh
```

## Lab: install from feed URL

```sh
FWLIVE_FEED_BASE_URL=https://lucas-albers-lz4.github.io/fwlive-packages \
  ./scripts/validate-feed-smoke.sh --version 24.10
```

## Related

- [Release workflow](release.md)
- [Publish checklist](github-publish-checklist.md)
- [SDK build matrix](sdk-build-matrix.md)

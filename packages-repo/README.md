# fwlive-packages

Signed **opkg** / **apk** binary feed for [`luci-app-fwlive`](https://github.com/lucas-albers-lz4/fwlive) — LuCI **Firewall Live View** on OpenWrt.

**Live feed:** https://lucas-albers-lz4.github.io/fwlive-packages/

## Install

**Recommended — binary feed** (`opkg` on **21.02–24.10**, `apk` on **25.12+** from GitHub Pages). Full guide: [installation](https://github.com/lucas-albers-lz4/fwlive/blob/master/docs/user/installation.md#1-binary-feed-recommended).

**opkg (21.02.x – 24.10.x)** — run on the router. It picks the feed for your OpenWrt release:

```sh
BASE='https://lucas-albers-lz4.github.io/fwlive-packages'
. /etc/openwrt_release
feed="$(echo "$DISTRIB_RELEASE" | cut -d. -f1,2)"
case "$feed" in
  21.02|22.03|23.05|24.10) ;;
  *)
    echo "Release $DISTRIB_RELEASE uses apk — use the OpenWrt 25.12+ commands below" >&2
    exit 1
    ;;
esac
wget -O /tmp/fwlive.key "$BASE/public.key"
opkg-key add /tmp/fwlive.key
echo "src/gz fwlive $BASE/$feed" >> /etc/opkg/customfeeds.conf
opkg update && opkg install luci-app-fwlive
```

<details>
<summary>apk (25.12+) and more detail</summary>

**apk (25.12+)** — hardcoded example for OpenWrt **25.12**:

```sh
wget -O /tmp/fwlive-feed.rsa.pub https://lucas-albers-lz4.github.io/fwlive-packages/fwlive-feed.rsa.pub
mkdir -p /etc/apk/keys
cp /tmp/fwlive-feed.rsa.pub /etc/apk/keys/fwlive-feed.rsa.pub
echo 'https://lucas-albers-lz4.github.io/fwlive-packages/25.12/all/packages.adb' \
  >> /etc/apk/repositories.d/fwlive.list
apk update && apk add luci-app-fwlive
```

More detail: [binary feed](https://github.com/lucas-albers-lz4/fwlive/blob/master/docs/binary-feed.md) · per-release notes in [21.02](https://github.com/lucas-albers-lz4/fwlive/blob/master/docs/openwrt-21.02-compat.md) / [22.03](https://github.com/lucas-albers-lz4/fwlive/blob/master/docs/openwrt-22.03-compat.md) compat docs.

</details>

Menu after install: **Status → Firewall Live View**.

## About this repo

The **`gh-pages`** branch is deployed automatically by CI from the [fwlive](https://github.com/lucas-albers-lz4/fwlive) repository on each release tag. It contains signed package indexes and `_all` `.ipk` / `.apk` artifacts — not application source code.

- **Source + docs:** https://github.com/lucas-albers-lz4/fwlive  
- **Manual downloads:** https://github.com/lucas-albers-lz4/fwlive/releases  
- **Release manifest:** https://lucas-albers-lz4.github.io/fwlive-packages/manifest.json

## License

Packages are built from [fwlive](https://github.com/lucas-albers-lz4/fwlive) (Apache-2.0). OpenWrt/LuCI components in the built image retain their upstream licenses.

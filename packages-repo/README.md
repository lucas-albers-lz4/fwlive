# fwlive-packages

Signed **opkg** / **apk** binary feed for [`luci-app-fwlive`](https://github.com/lucas-albers-lz4/fwlive) — LuCI **Firewall Live View** on OpenWrt.

**Live feed:** https://lucas-albers-lz4.github.io/fwlive-packages/

## Install

**Recommended — binary feed.** Run this on the router. It picks the signed feed for OpenWrt **23.05**, **24.10** (`opkg`), or **25.12** (`apk`). Full guide: [installation](https://github.com/lucas-albers-lz4/fwlive/blob/master/docs/user/installation.md#1-binary-feed-recommended).

```sh
BASE='https://lucas-albers-lz4.github.io/fwlive-packages'
. /etc/openwrt_release
feed="$(echo "$DISTRIB_RELEASE" | cut -d. -f1,2)"
case "$feed" in
  23.05|24.10)
    wget -O /tmp/fwlive.key "$BASE/public.key"
    opkg-key add /tmp/fwlive.key
    mkdir -p /etc/opkg
    touch /etc/opkg/customfeeds.conf
    { grep -v '^src/gz fwlive ' /etc/opkg/customfeeds.conf || true; } > /etc/opkg/customfeeds.conf.tmp
    mv /etc/opkg/customfeeds.conf.tmp /etc/opkg/customfeeds.conf
    echo "src/gz fwlive $BASE/$feed" >> /etc/opkg/customfeeds.conf
    opkg update && opkg install luci-app-fwlive
    ;;
  25.12)
    wget -O /tmp/fwlive-feed.rsa.pub "$BASE/fwlive-feed.rsa.pub"
    mkdir -p /etc/apk/keys /etc/apk/repositories.d
    cp /tmp/fwlive-feed.rsa.pub /etc/apk/keys/fwlive-feed.rsa.pub
    printf '%s\n' "$BASE/$feed/all/packages.adb" > /etc/apk/repositories.d/fwlive.list
    apk update && apk add luci-app-fwlive
    ;;
  21.02|22.03)
    echo "OpenWrt $DISTRIB_RELEASE is unsupported; no published feed" >&2
    exit 1
    ;;
  *)
    echo "OpenWrt $DISTRIB_RELEASE is not a published fwlive feed (23.05/24.10 opkg, 25.12 apk)" >&2
    exit 1
    ;;
esac
```

Menu after install: **Status → Firewall Live View**.

## About this repo

The **`gh-pages`** branch is deployed automatically by CI from the [fwlive](https://github.com/lucas-albers-lz4/fwlive) repository on each release tag. It contains signed package indexes and `_all` `.ipk` / `.apk` artifacts — not application source code.

- **Source + docs:** https://github.com/lucas-albers-lz4/fwlive  
- **Manual downloads:** https://github.com/lucas-albers-lz4/fwlive/releases  
- **Release manifest:** https://lucas-albers-lz4.github.io/fwlive-packages/manifest.json

## License

Packages are built from [fwlive](https://github.com/lucas-albers-lz4/fwlive) (Apache-2.0). OpenWrt/LuCI components in the built image retain their upstream licenses.

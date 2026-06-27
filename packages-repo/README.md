# fwlive-packages

Signed **opkg** / **apk** binary feed for [`luci-app-fwlive`](https://github.com/lucas-albers-lz4/fwlive) — LuCI **Firewall Live View** on OpenWrt.

**Live feed:** https://lucas-albers-lz4.github.io/fwlive-packages/

## Install

See the [installation guide](https://github.com/lucas-albers-lz4/fwlive/blob/main/docs/user/installation.md#1-binary-feed-recommended) in the main repo. Quick example for **OpenWrt 24.10**:

```sh
wget -O /tmp/fwlive.key https://lucas-albers-lz4.github.io/fwlive-packages/public.key
opkg-key add /tmp/fwlive.key
echo 'src/gz fwlive https://lucas-albers-lz4.github.io/fwlive-packages/24.10' >> /etc/opkg/customfeeds.conf
opkg update && opkg install luci-app-fwlive
```

Use feed path `…/23.05` for OpenWrt 23.05, `…/22.03` for **22.03.x (EOL)**, `…/21.02` for legacy **21.02.x (fw3)**. For **25.12+** (`apk`), see [binary-feed.md](https://github.com/lucas-albers-lz4/fwlive/blob/main/docs/binary-feed.md#openwrt-2512-apk).

Menu after install: **Status → Firewall Live View**.

## About this repo

The **`gh-pages`** branch is deployed automatically by CI from the [fwlive](https://github.com/lucas-albers-lz4/fwlive) repository on each release tag. It contains signed package indexes and `_all` `.ipk` / `.apk` artifacts — not application source code.

- **Source + docs:** https://github.com/lucas-albers-lz4/fwlive  
- **Manual downloads:** https://github.com/lucas-albers-lz4/fwlive/releases  
- **Release manifest:** https://lucas-albers-lz4.github.io/fwlive-packages/manifest.json

## License

Packages are built from [fwlive](https://github.com/lucas-albers-lz4/fwlive) (Apache-2.0). OpenWrt/LuCI components in the built image retain their upstream licenses.

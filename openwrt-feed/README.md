# OpenWrt feed: `luci-app-fwlive`

Third-party feed containing one package: **LuCI Firewall Live View**.

## Documentation

| Audience | Link |
|----------|------|
| **Install & use on a router** | [`../docs/user/README.md`](../docs/user/README.md) |
| **Build from source / develop** | [`../docs/developer/README.md`](../docs/developer/README.md) |

## Wire the feed

```sh
echo "src-link fwview /absolute/path/to/fwview/openwrt-feed" >> feeds.conf
./scripts/feeds update fwview
./scripts/feeds install luci-app-fwlive
```

Template: [`../feeds.conf.example`](../feeds.conf.example)

Enable in `menuconfig`: **LuCI → Applications → luci-app-fwlive**

## Build paths

| Path | When |
|------|------|
| **Docker SDK** (recommended) | [`../docs/developer/build-and-test.md`](../docs/developer/build-and-test.md) |
| **Full OpenWrt tree** | [`../docs/openwrt-full-source-build.md`](../docs/openwrt-full-source-build.md) |
| **Native SDK tarball** | [`../docs/minimal-build-sdk.md`](../docs/minimal-build-sdk.md) |

## Runtime

- **nftables / firewall4** only (`/usr/sbin/nft`)
- Reads **`ubus log.read`** — firewall rules must **`log`** matching traffic
- See [`../docs/user/enabling-firewall-logs.md`](../docs/user/enabling-firewall-logs.md)

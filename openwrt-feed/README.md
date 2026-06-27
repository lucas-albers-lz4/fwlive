# OpenWrt feed: `luci-app-fwlive`

Third-party feed containing one package: **LuCI Firewall Live View**.

## Documentation

| Audience | Link |
|----------|------|
| **Install & use on a router** | [`../docs/user/README.md`](../docs/user/README.md) |
| **Build from source / develop** | [`../docs/developer/README.md`](../docs/developer/README.md) |

## Distribution

| Path | Audience |
|------|----------|
| **[GitHub Releases](https://github.com/lucas-albers-lz4/fwlive/releases)** | Router owners — prebuilt `.ipk` / `.apk` |
| **`src-link` feed** (below) | Firmware / SDK builders |
| **Docker SDK** | Contributors — see [build & test](../docs/developer/build-and-test.md) |

Maintainers: [Release workflow](../docs/release.md)

## Wire the feed

```sh
git clone https://github.com/lucas-albers-lz4/fwlive.git
echo "src-link fwlive /absolute/path/to/fwlive/openwrt-feed" >> feeds.conf
./scripts/feeds update fwlive
./scripts/feeds install luci-app-fwlive
```

Template: [`../feeds.conf.example`](../feeds.conf.example)

Use **`src-link`** with an absolute path after cloning. Do **not** use `src-git` on the main `fwlive` repo — packages live under `openwrt-feed/`, not the repo root.

Enable in `menuconfig`: **LuCI → Applications → luci-app-fwlive**

## Build paths

| Path | When |
|------|------|
| **Docker SDK** (recommended) | [`../docs/developer/build-and-test.md`](../docs/developer/build-and-test.md) |
| **Full OpenWrt tree** | [`../docs/openwrt-full-source-build.md`](../docs/openwrt-full-source-build.md) |
| **Native SDK tarball** | [`../docs/minimal-build-sdk.md`](../docs/minimal-build-sdk.md) |

## Runtime

- Menu visible when **`/usr/sbin/nft`** or **`/usr/sbin/iptables`** is executable (no hard `firewall4` package dependency)
- **fw4/nft** primary on **22.03+**; **iptables LOG** primary on legacy **21.02.x** (fw3), best-effort on 22.03+ when nft absent
- Polls **`ubus fwlive poll`** (filtered firewall log lines from logd) — firewall rules must **`log`** matching traffic
- See [`../docs/user/enabling-firewall-logs.md`](../docs/user/enabling-firewall-logs.md)

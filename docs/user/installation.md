# Installation

Four paths: **opkg/apk feed** (recommended for router owners), **GitHub Release** download, **feed via `src-link`** (builders), or **Docker SDK** (developers / lab).

## 1. Binary feed (recommended)

Install directly from the signed GitHub Pages feed — no manual download.

| OpenWrt | Package manager | Feed doc |
|---------|-----------------|----------|
| **23.05** / **24.10** | `opkg` | [Binary feed — opkg](../binary-feed.md#openwrt-2410-opkg) |
| **25.12+** | `apk` | [Binary feed — apk](../binary-feed.md#openwrt-2512-apk) |

**OpenWrt 24.10** example:

```sh
wget -O /tmp/fwlive.key https://lucas-albers-lz4.github.io/fwlive-packages/public.key
opkg-key add /tmp/fwlive.key
echo 'src/gz fwlive https://lucas-albers-lz4.github.io/fwlive-packages/24.10' >> /etc/opkg/customfeeds.conf
opkg update && opkg install luci-app-fwlive
```

Use `…/23.05` for OpenWrt 23.05. For 25.12+, see the apk section in [binary-feed.md](../binary-feed.md).

## 2. GitHub Release (manual download)

Download the prebuilt package from **[GitHub Releases](https://github.com/lucas-albers-lz4/fwlive/releases)** for your OpenWrt version.

| OpenWrt | Artifact | Package manager |
|---------|----------|-----------------|
| **23.05** / **24.10** | `luci-app-fwlive_*_all.ipk` | `opkg` |
| **25.12+** | `luci-app-fwlive-*.apk` | `apk` |

The package is **`_all`** — architecture-independent. One `.ipk` or `.apk` per OpenWrt release works on any router (ARM, x86, etc.).

Copy to the router and install:

**OpenWrt 23.05 / 24.10** (`opkg`):

```sh
scp luci-app-fwlive_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 opkg install /tmp/luci-app-fwlive_*.ipk
```

**OpenWrt 25.12+** (`apk`):

```sh
scp luci-app-fwlive-*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 apk add --allow-untrusted /tmp/luci-app-fwlive-*.apk
```

Refresh LuCI in the browser. The menu appears under **Status → Firewall Live View**.

## 2. Feed via src-link (builders)

Use when you compile firmware or run the official OpenWrt SDK and want `luci-app-fwlive` in your tree.

1. Clone this repository on your build machine:

   ```sh
   git clone https://github.com/lucas-albers-lz4/fwlive.git
   ```

2. Register the feed with an **absolute path** to `openwrt-feed/`:

   ```sh
   echo "src-link fwlive /absolute/path/to/fwlive/openwrt-feed" >> feeds.conf
   ./scripts/feeds update fwlive
   ./scripts/feeds install luci-app-fwlive
   ```

   Template: [`feeds.conf.example`](../../feeds.conf.example)

   **Note:** Do **not** use `src-git` pointing at the main `fwlive` repo. OpenWrt expects packages at the feed checkout root; this monorepo keeps the feed under `openwrt-feed/`. Use `src-link` after clone.

3. Enable in `menuconfig`: **LuCI → Applications → luci-app-fwlive**

4. Build:

   ```sh
   make package/luci-app-fwlive/compile V=s
   ```

   Install the resulting file from `bin/packages/.../luci-app-fwlive_*.ipk` (or `.apk` on newer branches).

## 3. Docker SDK (developers / lab)

On **Linux x86_64**:

```sh
./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10
# or for x86 router / QEMU lab:
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
```

Packages land under `out/<arch>/<version>/fwlive/`. Deploy with `scp` + `opkg`/`apk` as in section 1.

For a full QEMU lab loop (build → boot → install), see [Developer: QEMU lab](../developer/qemu-lab.md).

## After install

1. Confirm the menu: **Status → Firewall Live View**
2. [Enable firewall logging](enabling-firewall-logs.md) — the table stays empty until rules log traffic
3. Read [Using the UI](using-the-ui.md)

## Uninstall

```sh
opkg remove luci-app-fwlive    # 23.05 / 24.10
apk del luci-app-fwlive        # 25.12+
```

No persistent firewall changes are made by the package itself.

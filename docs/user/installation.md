# Installation

Most users install from the **[binary feed](#1-binary-feed-recommended)**. It needs no manual download. When the feed does not work for you, use the other methods.

## 1. Binary feed (recommended)

Install directly from the signed GitHub Pages feed — no manual download.

| OpenWrt | Package manager | Feed doc |
|---------|-----------------|----------|
| **21.02.x** (legacy fw3) | `opkg` | [Binary feed — 21.02](../binary-feed.md#openwrt-2102x-opkg-legacy-fw3) |
| **22.03.x** (EOL) | `opkg` | [Binary feed — 22.03](../binary-feed.md#openwrt-2203x-opkg-eol) |
| **23.05** / **24.10** | `opkg` | [Binary feed — opkg](../binary-feed.md#openwrt-2305--2410-opkg) |
| **25.12+** | `apk` | [Binary feed — apk](../binary-feed.md#openwrt-2512-apk) |

**OpenWrt 24.10** example:

```sh
wget -O /tmp/fwlive.key https://lucas-albers-lz4.github.io/fwlive-packages/public.key
opkg-key add /tmp/fwlive.key
echo 'src/gz fwlive https://lucas-albers-lz4.github.io/fwlive-packages/24.10' >> /etc/opkg/customfeeds.conf
opkg update && opkg install luci-app-fwlive
```

Use `…/23.05` for OpenWrt 23.05, `…/22.03` for **22.03.x**, `…/21.02` for legacy **21.02.x (fw3)**. For 25.12+, see the apk section in [binary-feed.md](../binary-feed.md).

<details>
<summary>Other install methods</summary>

Use these methods when the binary feed does not work for you. Most users do not need them.

## 2. GitHub Release (manual download)

Download the prebuilt package from **[GitHub Releases](https://github.com/lucas-albers-lz4/fwlive/releases)** for your OpenWrt version.

| OpenWrt | Artifact | Package manager |
|---------|----------|-----------------|
| **21.02.x** / **22.03.x** / **23.05** / **24.10** | `luci-app-fwlive_*_all.ipk` | `opkg` |
| **25.12+** | `luci-app-fwlive-*.apk` | `apk` |

The package is **`_all`** — architecture-independent. One `.ipk` or `.apk` per OpenWrt release works on any router (ARM, x86, etc.).

Copy to the router and install:

**OpenWrt 21.02 / 22.03 / 23.05 / 24.10** (`opkg`):

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

## 3. Feed via src-link (builders)

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

## 4. Docker SDK (developers / lab)

On **Linux x86_64**:

```sh
./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10
# or for x86 router / QEMU lab:
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
```

Packages land under `out/<arch>/<version>/fwlive/`. Deploy with `scp` + `opkg`/`apk` as in section 1.

For a full QEMU lab loop (build → boot → install), see [Developer: QEMU lab](../developer/qemu-lab.md).

</details>

## After install

1. Confirm the menu: **Status → Firewall Live View**
2. **[Enable logging — quick start](enabling-firewall-logs.md#quick-start-after-install)** — the table is empty on stock configs until you turn logging on. Run the WAN zone one-liner there to see real drop/reject traffic, or the ping test for a quick pass row.
3. Read [Using the UI](using-the-ui.md)

## Upgrading

Re-install the new version over the existing one. No configuration migration is needed — the package makes no persistent firewall changes.

**opkg (21.02 – 24.10):**
```sh
opkg update && opkg install luci-app-fwlive
```

**apk (25.12+):**
```sh
apk update && apk add luci-app-fwlive
```

After upgrade, refresh the LuCI page in your browser (may need a cache-busting hard refresh: Ctrl+Shift+R / Cmd+Shift+R).

## Uninstall

```sh
opkg remove luci-app-fwlive    # 21.02 / 22.03 / 23.05 / 24.10
apk del luci-app-fwlive        # 25.12+
```

No persistent firewall changes are made by the package itself.

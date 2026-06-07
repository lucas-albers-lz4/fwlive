# Installation

Three common paths: **prebuilt package**, **feed in your build**, or **SDK output from this repo**.

## Option A — Install a prebuilt package (fastest)

On the router (or QEMU lab), copy the artifact and install:

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

## Option B — Add this feed to your OpenWrt build

Use when you already compile firmware or run the official SDK.

1. Clone this repository on your build machine.

2. Register the feed (adjust the path):

   ```sh
   echo "src-link fwview /absolute/path/to/fwview/openwrt-feed" >> feeds.conf
   ./scripts/feeds update fwview
   ./scripts/feeds install luci-app-fwlive
   ```

   Template: [`feeds.conf.example`](../../feeds.conf.example)

3. Enable in `menuconfig`: **LuCI → Applications → luci-app-fwlive**

4. Build:

   ```sh
   make package/luci-app-fwlive/compile V=s
   ```

   Install the resulting file from `bin/packages/.../luci-app-fwlive_*.ipk` (or `.apk` on newer branches).

## Option C — Build with this repo’s Docker SDK (developers / lab)

On **Linux x86_64**:

```sh
./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10
# or for x86 router / QEMU lab:
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
```

Packages land under `out/<arch>/<version>/fwview/`. Deploy with `scp` + `opkg`/`apk` as in option A.

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

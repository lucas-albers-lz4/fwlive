# Custom OpenWrt feed: `luci-app-fwlive`

OpenWrt separates **build logic** (packages under `package/`, `feeds/*/`) from **distribution** via **feeds**. The official LuCI tree is itself a feed; applications inside it use `include ../../luci.mk`. This directory is a **small third-party feed**: one package at the top level, which is a normal pattern for `src-link` or a dedicated git repo.

## Minimal path: OpenWrt SDK (no full image)

For day-to-day work you only need the **SDK** for your target architecture (same OpenWrt release as the router). **Recommended:** develop on **Linux x86_64** (e.g. **Ubuntu**) and build **natively** or with optional Docker (**`USE_SDK_BIND=1`**). See **[`../docs/minimal-build-sdk.md`](../docs/minimal-build-sdk.md)** (includes **macOS** Docker volume flow and **[`../docker-compose.yml`](../docker-compose.yml)**).

## Deploy the `.ipk`

- **Router on LAN:** `scp` to **`root@<router-ip>:22`**, then `opkg install` (see minimal-build-sdk).
- **QEMU on macOS with vmnet:** use the guest’s **real IP**, **SSH port 22**, LuCI **80**/**443** — not **`127.0.0.1:2222`** / **`:8080`** unless you run QEMU with user networking + **hostfwd**. Helper: **`../scripts/agent-build-and-deploy.sh`** (`QEMU_MAC_LAN` / `OPENWRT_HOST`, or **`--legacy-hostfwd`** for mapped **2222**/**8080**).

## Wire into OpenWrt 24.10 buildroot (or SDK — same feed steps)

1. Check out OpenWrt (e.g. `openwrt-24.10` branch) and install the **LuCI** feed so `$(TOPDIR)/feeds/luci/luci.mk` exists:

   ```sh
   ./scripts/feeds update luci packages
   ./scripts/feeds install luci-base
   ```

2. Register this feed (absolute path to this `openwrt-feed` directory):

   ```sh
   echo "src-link fwview /absolute/path/to/fwview/openwrt-feed" >> feeds.conf
   ./scripts/feeds update fwview
   ./scripts/feeds install luci-app-fwlive
   ```

3. Enable in `menuconfig`: **LuCI → Applications → luci-app-fwlive** (or `make menuconfig` search for `fwlive`).

4. Build:

   ```sh
   make package/luci-app-fwlive/compile V=s
   ```

   Or build a full image for your `x86_64` / `armvirt` profile as usual.

## Alternative: patch into the LuCI feed tree

If you maintain a fork of `openwrt/luci`, you can copy `openwrt-feed/luci-app-fwlive/` into `luci/applications/luci-app-fwlive/` and use `include ../../luci.mk` in the Makefile instead of `$(TOPDIR)/feeds/luci/luci.mk`—same sources, different layout.

## Runtime notes

- **nftables only**: menu entry depends on `/usr/sbin/nft`.
- Log data comes from **`ubus log.read`** (logd); ensure firewall drop/accept rules use **log** where you need visibility.
- How this relates to OPNsense Live View (logging layer, not PF): **[`../docs/opnsense-liveview-understanding.md`](../docs/opnsense-liveview-understanding.md)**.

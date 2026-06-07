# Custom OpenWrt feed: `luci-app-fwlive`

OpenWrt separates **build logic** (packages under `package/`, `feeds/*/`) from **distribution** via **feeds**. The official LuCI tree is itself a feed; applications inside it use `include ../../luci.mk`. This directory is a **small third-party feed**: one package at the top level, which is a normal pattern for `src-link` or a dedicated git repo.

## Build paths (same feed wiring)

**Start here:** **[`../docs/dev-environment.md`](../docs/dev-environment.md)** — **Linux x86_64** host, official **`ghcr.io/openwrt/sdk:armsr-armv8`**, cross-build for **`armsr/armv8`**.

- **SDK (recommended):** **`../scripts/docker-sdk.sh`** — **[`../docs/sdk-build-matrix.md`](../docs/sdk-build-matrix.md)** · **[`../docs/minimal-build-sdk.md`](../docs/minimal-build-sdk.md)**.
- **Full OpenWrt source (optional):** **[`../docs/openwrt-full-source-build.md`](../docs/openwrt-full-source-build.md)**.

## Deploy the `.ipk`

- **Router on LAN:** `scp` + `opkg install` (see minimal-build-sdk).
- **QEMU lab:** LuCI `http://127.0.0.1:8080`, SSH `ssh -p 2222 root@127.0.0.1` — **`../scripts/qemu-install-fwlive.sh`** or **`../scripts/agent-build-and-deploy.sh --legacy-hostfwd`**.

## Wire into OpenWrt 24.10 (full tree or SDK — same feed steps)

1. Check out OpenWrt (e.g. `openwrt-24.10` branch) and install the **LuCI** feed so `$(TOPDIR)/feeds/luci/luci.mk` exists:

   ```sh
   ./scripts/feeds update luci packages
   ./scripts/feeds install luci-base
   ```

2. Register this feed — see **`../feeds.conf.example`**:

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

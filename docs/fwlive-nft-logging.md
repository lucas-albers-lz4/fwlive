# Enable firewall logs for Firewall Live View

**Firewall Live View** reads **`ubus log.read`** (logd). The UI only shows traffic when **nftables / fw4** rules **log** matching packets.

## Quick test on a running guest

SSH into the router or QEMU guest, then:

```sh
# Generate traffic and log new INPUT drops (example)
nft add rule inet fw4 input iifname "eth0" tcp dport 9999 log prefix "fwlive-test: " drop
```

From another host, connect to port **9999** on the guest LAN IP (or use `wget` / `nc` through QEMU port forwards). You should see lines in **Status → Firewall Live View** containing **`fwlive-test:`** and **`SRC=`** / **`DST=`** key/value fields.

Remove the test rule when done:

```sh
nft -a list chain inet fw4 input   # note handle number
nft delete rule inet fw4 input handle <N>
```

## fw4 / UCI (persistent)

For **firewall4**, add **`log`** on the rules you care about in **`/etc/config/firewall`** (exact syntax depends on your OpenWrt version). A common pattern is extra **`option log '1'`** on a rule or using **`log`** in custom nft includes under **`/etc/nftables.d/`**.

After changes:

```sh
fw4 reload
logread -f | grep -i drop    # CLI sanity check
```

## What the parser expects

Log messages should include netfilter-style tokens such as **`IN=`**, **`OUT=`**, **`SRC=`**, **`DST=`**, **`PROTO=`**, **`SPT=`**, **`DPT=`**, and an action word (**`DROP`**, **`ACCEPT`**, etc.). See [`openwrt-fwlive-schema.md`](openwrt-fwlive-schema.md).

## Still empty?

- Confirm **`/usr/sbin/nft`** exists (menu is hidden without it).
- Confirm **`luci-app-fwlive`** and **`luci-base`** are installed.
- Run **`logread`** on the device — if nothing appears there, the UI will stay empty too.

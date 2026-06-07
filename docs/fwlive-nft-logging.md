# Enable firewall logs for Firewall Live View

**Firewall Live View** reads **`ubus log.read`** (logd). The UI only shows traffic when **nftables / fw4** rules **log** matching packets.

## Log ping traffic (recommended quick test)

Ping is easy to generate and does not need a special open port. **Insert** at the top of `input` — rules **appended** to `input` are skipped for LAN traffic (`jump input_lan`).

On the guest as **root**:

```sh
nft insert rule inet fw4 input ip protocol icmp icmp type echo-request log prefix "fwlive-ping " accept
```

Optional IPv6:

```sh
nft insert rule inet fw4 input ip6 nexthdr ipv6-icmpv6 icmpv6 type echo-request log prefix "fwlive-ping6 " accept
```

From the build host (**QEMU x86 lab** — recommended):

```sh
./scripts/fwlive-nft-ping-log.sh add --ssh
# Slirp user networking: host→guest ICMP often fails — generate on the guest:
ssh -p 2222 root@127.0.0.1 'ping -c 5 127.0.0.1'
./scripts/fwlive-ubus-read.sh --lines 30
# LuCI: http://localhost:8080/cgi-bin/luci/admin/status/fwlive
```

From the build host (Docker experiment):

```sh
chmod +x ./scripts/fwlive-nft-ping-log.sh
./scripts/fwlive-nft-ping-log.sh add
GUEST_IP=$(./scripts/fwlive-nft-ping-log.sh guest-ip)
ping -c 5 "$GUEST_IP"
./scripts/fwlive-ubus-read.sh --lines 30
```

On the guest, confirm kernel/firewall lines:

```sh
logread | grep -E 'fwlive-ping|SRC='
```

Remove when done:

```sh
./scripts/fwlive-nft-ping-log.sh remove
# or: nft -a list chain inet fw4 input | grep fwlive-ping
#     nft delete rule inet fw4 input handle <N>
```

**Note:** avoid `:` in the prefix on the shell (see below). Use `fwlive-ping ` not `fwlive-ping:`.

## Quick test on a running guest (TCP)

SSH into the router or QEMU guest, then:

```sh
# Log + drop TCP port 9999 on INPUT (test rule)
# Note: avoid ':' inside the prefix — OpenWrt ash/nft often strips quotes and
# then treats the colon as nft syntax (your error). Use a trailing space instead.
nft add rule inet fw4 input tcp dport 9999 log prefix "fwlive-test " drop
```

**Do not use** `prefix "fwlive-test: "` on the shell — it commonly fails with:

```text
Error: syntax error, unexpected colon ...
add rule ... log prefix fwlive-test: drop
```

If you need awkward characters, use an nft snippet file:

```sh
nft -f - <<'EOF'
add rule inet fw4 input tcp dport 9999 log prefix "fwlive-test: " drop
EOF
```

**Interface:** you usually do **not** need `iifname "eth0"`. On Docker/LuCI experiments the LAN bridge is often **`br-lan`**, not `eth0`. A plain `tcp dport` rule at the end of `input` is enough for a test.

Generate traffic **from another host** (not loopback — `iif lo accept` runs first):

```sh
# From build host, if guest SSH is on 2222 and you add a temporary forward, or from LAN:
nc -vz <guest-lan-ip> 9999
# or
wget -q -O /dev/null --timeout=2 http://<guest-lan-ip>:9999/
```

Check logs on the guest:

```sh
logread | grep -E 'fwlive-test|SRC=|DST='
./scripts/fwlive-ubus-read.sh --lines 20   # from build host
```

You should see lines with **`fwlive-test`** and **`SRC=`** / **`DST=`** in **Firewall Live View**.

Remove test rules when done:

```sh
nft -a list chain inet fw4 input   # note handle numbers at end of chain
nft delete rule inet fw4 input handle <N>
```

## fw4 / UCI (persistent)

For **firewall4**, add **`log`** on the rules you care about in **`/etc/config/firewall`** (exact syntax depends on your OpenWrt version). A common pattern is **`option log '1'`** on a rule or a custom nft snippet under **`/etc/nftables.d/`**.

After changes:

```sh
fw4 reload
logread -f | grep -E 'SRC=|DROP|ACCEPT'
```

## What the parser expects

Log messages should include netfilter-style tokens such as **`IN=`**, **`OUT=`**, **`SRC=`**, **`DST=`**, **`PROTO=`**, **`SPT=`**, **`DPT=`**, and an action word (**`DROP`**, **`ACCEPT`**, etc.). See [`openwrt-fwlive-schema.md`](openwrt-fwlive-schema.md).

## Rule matches but `logread` stays empty?

Split **rule matching** from **kernel logging**:

### 1. Confirm traffic hits the rule (counter)

Add **`counter`** to the same rule (or use the top rule from `fwlive-nft-ping-log.sh add`):

```sh
nft insert rule inet fw4 input ip protocol icmp icmp type echo-request counter log prefix "fwlive-hit " accept
```

Ping from **another host** (not `ping 127.0.0.1` on the guest — loopback is accepted before your rule):

```sh
ping -c 5 "$(ip -4 addr show br-lan | awk '/inet /{print $2}' | cut -d/ -f1)"
```

Check the counter:

```sh
nft -a list chain inet fw4 input | grep -E 'fwlive-hit|counter'
```

If **`packets`** increases when you ping, the rule is correct — the problem is only the **log → logd** path.

### 2. Docker x86 `rootfs` experiment (common cause)

In **`ghcr.io/openwrt/rootfs:x86-64`**, `uname -r` is usually the **host kernel** (e.g. `6.8.0-…-generic`), while OpenWrt kmods under `/lib/modules/` target the **OpenWrt kernel** (e.g. `6.18.33`). **`nft counter`** and **`accept`** still work; **`nft log`** often **never reaches `logread`**.

Check:

```sh
uname -r
ls /lib/modules/
modprobe nf_log_ipv4   # may report "no module folders for kernel version …"
logread | grep -E 'fwlive-ping|SRC='
```

For **real firewall log testing**, use **QEMU armsr** with a full OpenWrt image (guest runs the OpenWrt kernel) or hardware — not the Docker rootfs lab.

See also [`openwrt-rootfs-x86-docker.md`](openwrt-rootfs-x86-docker.md).

### 3. UI / parser dev workaround (Docker only)

Inject a firewall-shaped line that **does** reach logd:

```sh
logger -t kernel -p kern.info "fwlive-test IN=br-lan SRC=172.17.0.1 DST=172.17.0.2 PROTO=ICMP ACCEPT"
logread | tail -3
./scripts/fwlive-ubus-read.sh --lines 5   # from build host
```

That validates **Live View + parser**; it does not prove **`nft log`** works in that environment.

### 4. Other checks

- **fw4 exists** but rules may not **`log`** — empty UI is normal until they do.
- Rule at **end** of `input` never sees LAN pings — use **`nft insert`** at the top (before `jump input_lan`).
- Confirm **`kmod-nf-log`** / **`kmod-nf-log6`** on minimal images; **`cat /proc/sys/net/netfilter/nf_log/2`** should be **`nf_log_ipv4`**.
- Confirm **`/usr/sbin/nft`** exists (menu is hidden without it).
- Confirm **`luci-app-fwlive`** and **`luci-base`** are installed.
- Run **`logread | grep SRC=`** — if nothing there, the UI stays empty too.
- Stage 1 filter hides dnsmasq/procd noise; only firewall-shaped lines count.

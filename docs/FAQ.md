# Frequently Asked Questions

## Installation & Setup

### The table is empty after install — what's wrong?

**Nothing.** Stock OpenWrt images log almost no firewall traffic by default. You need to turn logging on.

Fastest path: open **Status → Firewall Live View** and click the **Enable logging** button. This enables WAN zone drop/reject logging. See the full [Enabling firewall logs](user/enabling-firewall-logs.md) guide.

### Can I install without the binary feed?

Yes. Download the `.ipk` / `.apk` from [GitHub Releases](https://github.com/lucas-albers-lz4/fwlive/releases) and install manually. See the [Installation guide](user/installation.md#2-github-release-manual-download).

### Which OpenWrt version should I use?

**23.05+** for firewall4/nft (recommended). 22.03 works but is EOL. 21.02 works for fw3/iptables but is also EOL. See [Requirements](user/requirements.md).

### Does this work on any router?

Yes. The package is **`_all`** (architecture-independent LuCI JS + shell) — one build works on any OpenWrt-supported CPU architecture (ARM, MIPS, x86, etc.).

---

## Usage

### Why don't I see my LAN browsing traffic?

Zone logging only logs **rejected and dropped** traffic on that zone. Normal LAN→WAN accepted traffic doesn't appear unless you add explicit **`log`** rules. See [Rule-level logging](user/enabling-firewall-logs.md#rule-level-logging-specific-policies).

### How do I see only dropped packets?

Click a **drop** cell in the table, or use the **Action** filter → **drop**. You can also click the **pass** cell then click **≠** on the chip to exclude passes.

### How do I share my current view with someone?

The URL hash stores all active filters, limit, and view mode. Just copy the URL from your browser address bar.

### Why do some rows have no Rule column data?

Live View shows a **Rule** label only when the nft log line includes a **prefix** (e.g. `log prefix "my-rule "`) and fw4 can resolve it to a UCI rule name. Rules without `log prefix` don't carry enough metadata.

### What does "Enable logging" on the page actually do?

It sets `option log '1'` on your WAN firewall zone via ubus. This enables logging of rejected and dropped packets on the WAN interface. It does **not** log accepted LAN traffic.

---

## Troubleshooting

### The UI stays empty but I see firewall lines in `logread`

Check that:
1. `luci-app-fwlive` and `luci-base` are installed
2. You're logged into LuCI (the page shows live data only after authentication)
3. The menu appears at **Status → Firewall Live View**
4. `logread | grep SRC=` shows lines — if not, fix firewall logging first

Run from SSH:
```sh
logread | grep -E 'SRC=|DST=|PROTO=' | tail
ubus call fwlive poll '{"addresses":["20"]}' | head -c 500
```

### My `nft log` rule matches (counter increases) but `logread` stays empty

Most common cause on Docker or minimal images: kernel logging modules are missing. Check:

```sh
cat /proc/sys/net/netfilter/nf_log/2    # should be nf_log_ipv4, not "none"
```

If missing, install `kmod-nf-log-ipv4` / `kmod-nf-log-ipv6`. See [Kernel module check](user/enabling-firewall-logs.md#3-check-kernel-logging-modules-only-if-logs-are-missing).

### Docker rootfs experiment: `nft log` doesn't work

Docker containers use the **host kernel**, not the OpenWrt kernel. `nft` counters and accept/drop work, but **`nft log` often never reaches `logread`** because kernel modules don't match.

Workaround: inject a fake firewall line manually:
```sh
logger -t kernel -p kern.info "fwlive-test IN=br-lan SRC=172.17.0.1 DST=172.17.0.2 PROTO=ICMP ACCEPT"
```

For real `nft log` testing, use QEMU armsr or hardware.

### "Premature end of file" when adding the opkg feed key

The `OPKG_FEED_SECRET_KEY` GitHub secret must contain the full usign secret with its line break. If it was pasted as one line, usign fails. Store `base64 -w0 opkg-secret.key` in the secret and decode in CI. See [binary-feed.md](binary-feed.md#common-mistakes).

### The flood banner appears but traffic is quiet

The token bucket charges new events per poll. A sudden burst of logs (e.g. port scan) can briefly trigger it. If it persists, check for a noisy firewall rule and add a rate limit (`log_limit` on zones, `limit rate` on nft rules).

---

## Building & Contributing

### Can I build this on macOS or Windows?

**No.** OpenWrt SDKs are `Linux-x86_64` only. You can edit JS/docs on any platform and run parser tests (`./scripts/fwlive-test.sh`) locally with Node. SDK builds and QEMU labs need a Linux x86_64 machine (or VM).

### Do I need a full OpenWrt buildroot?

No. The [Docker SDK](developer/build-and-test.md#sdk-builds) or a [minimal SDK tarball](minimal-build-sdk.md) is enough to build the package. A full buildroot is only needed for custom firmware images.

### I changed the parser — why is LuCI not showing my changes?

The LuCI `log.js` is a mirror of `core/fwlive-log.js`. You must update **both** files. Run `./scripts/fwlive-test.sh` to verify sync, then `./scripts/qemu-install-fwlive.sh` to copy to the running guest.

### How do I run tests without a router or QEMU?

```sh
./scripts/fwlive-test.sh
./scripts/validate-baseline.sh
```

These run parser, schema, and filter tests against fixtures — no hardware needed.

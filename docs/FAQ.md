# Frequently Asked Questions

## Installation & Setup

### The table is empty after install — what is wrong?

**Nothing.** Stock images log almost nothing until you turn logging on. See [Using the UI → First visit](user/using-the-ui.md#first-visit) and [Enabling firewall logs → Quick start](user/enabling-firewall-logs.md#quick-start-after-install).

### Can I install without the binary feed?

Yes. Download the `.ipk` / `.apk` from [GitHub Releases](https://github.com/lucas-albers-lz4/fwlive/releases) and install manually. See the [Installation guide](user/installation.md#2-github-release-manual-download).

### Which OpenWrt version should I use?

**23.05+** for firewall4/nft on older images; prefer **24.10+** for new deployments (23.05 is EOL). OpenWrt 21.02 and 22.03 are unsupported. See [Requirements](user/requirements.md).

### Does this work on any router?

Yes. The package is **`_all`** (architecture-independent LuCI JS + shell) — one build works on any OpenWrt-supported CPU architecture (ARM, MIPS, x86, etc.).

---

## Usage

### Why do I not see my LAN browsing traffic?

Zone logging only logs **rejected and dropped** traffic on that zone. Normal LAN→WAN accepted traffic does not appear unless you add explicit **`log`** rules. See [Beyond WAN drops](user/enabling-firewall-logs.md#beyond-wan-drops).

### How do I see only dropped packets?

Click a **drop** cell in the table, or use the **Action** filter → **drop**. You can also click the **pass** cell then click **≠** on the chip to exclude passes.

### How do I share my current view with someone?

The URL hash stores all active filters, limit, view mode, and — in Manual fetch mode — `poll=manual` and `maxraw=` (raw-line budget). Just copy the URL from your browser address bar.

### Why do some rows have no Rule column data?

Live View shows a **Rule** label only when the nft log line includes a **prefix** (e.g. `log prefix "my-rule "`) and fw4 can resolve it to a UCI rule name. Rules without `log prefix` do not carry enough metadata.

### What does "Enable logging" on the page actually do?

It sets `option log '1'` on your WAN firewall zone via ubus and reloads the firewall. That enables logging of **rejected and dropped** packets on WAN. It does **not** add allow/deny rules and does **not** log normal LAN browsing. Click **WAN logging on** on the watch strip to turn it off again.

---

## Troubleshooting

### Why does the page warn about a legacy iptables table?

The warning is diagnostic. It does not block **Enable logging**. It means `/proc/net/ip_tables_names` or `ip6_tables_names` in the rpcd network namespace listed a table name, so the live view may be incomplete. Loading `kmod-ipt-*` can write an empty built-in table name into those files, and a read-only `iptables-legacy -L` can register a name that then stays, so the warning can outlive the condition you think you cleared. firewall4/nft is the supported rules-map path; `iptables-nft` is compatible.

### The UI stays empty but I see firewall lines in `logread`

Check that:
1. `luci-app-fwlive` and `luci-base` are installed
2. You are logged into LuCI (the page shows live data only after authentication)
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
cat /proc/sys/net/netfilter/nf_log/2    # should be nf_log_ipv4, not NONE/none
```

An empty value or `NONE` (case-insensitive) means that family has no kernel
logging backend. Install `kmod-nf-log-ipv4` / `kmod-nf-log-ipv6` as needed.
IPv6 is checked independently through `/proc/net/if_inet6`. A missing or
empty file means the IPv6 stack is absent (compiled out or `ipv6.disable=1`)
and does not block WAN logging. Any content, including loopback `::1`, means
the IPv6 stack is present and `kmod-nf-log-ipv6` is required. A typical
IPv4-only WAN on stock OpenWrt still has `lo ::1` when `CONFIG_IPV6` is on.
See [Rule matches but `logread` stays empty](fwlive-nft-logging.md#rule-matches-but-logread-stays-empty).

### Docker rootfs experiment: `nft log` does not work

Docker containers use the **host kernel**, not the OpenWrt kernel. `nft` counters and accept/drop work, but **`nft log` often never reaches `logread`** because kernel modules do not match.

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

**No.** OpenWrt SDKs are `Linux-x86_64` only, and **Linux x86_64** is the only supported host for `./scripts/fwlive-test.sh`, SDK builds, and QEMU labs (GNU utilities, Bash ≥4). You may edit JS/docs on macOS or Windows; run host tests on Linux (VM, CI, or remote). See [Environment](developer/environment.md).

### Do I need a full OpenWrt buildroot?

No. The [Docker SDK](developer/build-and-test.md#sdk-builds) or a [minimal SDK tarball](minimal-build-sdk.md) is enough to build the package. A full buildroot is only needed for custom firmware images.

### I changed the parser — why is LuCI not showing my changes?

Edit `CLASSIFY_SPEC` in `core/fwlive-log.js` **and** the same object in `htdocs/.../fwlive/log.js`, then run `./scripts/gen-all.sh` (regenerates the shell classifier; gates LuCI full-spec drift — it does not rewrite LuCI shared logic). Run `./scripts/fwlive-test.sh`, then `./scripts/qemu-install-fwlive.sh` to copy to the running guest. Package builds do **not** run Node — committed artifacts are authoritative.

### How do I run tests without a router or QEMU?

```sh
./scripts/fwlive-test.sh
./scripts/validate-baseline.sh
```

These run parser, schema, and filter tests against fixtures — no hardware needed.

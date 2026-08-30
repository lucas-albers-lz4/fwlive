# Enabling firewall logs

Firewall Live View shows traffic only when **nftables / fw4** writes firewall-shaped lines to **logd**. The UI reads those lines. It does not tap the firewall directly.

**After a fresh install the table is usually empty.** Stock OpenWrt rarely logs traffic until you turn logging on.

---

## Quick start after install

Pick one path. Both produce visible traffic within seconds.

### Option A — LuCI button (recommended)

1. Open **Status → Firewall Live View**.
2. If logging is off, read the empty-state panel.
   Then click **Enable WAN drop/reject logging** (or **Enable logging** on the watch strip).
3. Wait for blocked inbound WAN traffic (background scans, rejected probes).

This sets WAN zone drop/reject logging only (same as **Network → Firewall**). It does not add allow/deny rules. Click **WAN logging on** on the watch strip to turn it off again. Rate limiting uses the OpenWrt default (`10/minute`) unless you set `log_limit` on the WAN zone.

Screenshot walkthrough: [Using the UI → First visit](using-the-ui.md#first-visit).

### Option B — shell (SSH or System → Terminal)

#### 1. Enable WAN zone logging (rejected / dropped inbound)

This is the fastest way to see **real** traffic without a synthetic ping test. fw4 adds log rules for **rejected and dropped** packets on that zone:

```sh
WAN=$(uci -q show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'$/\1/p" | head -1)
if [ -z "$WAN" ]; then
  echo "WAN zone not found in /etc/config/firewall" >&2
  exit 1
fi
uci set "firewall.${WAN}.log=1"
uci commit firewall
/etc/init.d/firewall reload
echo "Enabled zone logging on firewall.${WAN}"
```

OpenWrt applies the default **`log_limit`** (`10/minute`) when the option is not set in UCI.

To turn off:

```sh
uci delete "firewall.${WAN}.log"
uci commit firewall
/etc/init.d/firewall reload
```

#### 2. Optional — confirm the UI with a ping (synthetic pass events)

Useful when WAN is quiet or you want a guaranteed **pass** row:

```sh
nft insert rule inet fw4 input ip protocol icmp icmp type echo-request \
  log prefix "fwlive-ping " accept
ping -c 3 127.0.0.1
logread | grep fwlive-ping
```

Remove when finished:

```sh
nft -a list chain inet fw4 input | grep fwlive-ping
nft delete rule inet fw4 input handle <handle>
```

> **Note:** avoid `:` in `log prefix` on the shell — see [Prefix pitfalls](../fwlive-nft-logging.md#quick-test-on-a-running-guest-tcp).

## Verify before blaming the UI

```sh
logread | grep -E 'SRC=|DST=|PROTO=' | tail
ubus call fwlive poll '{"addresses":["20"]}' | head -c 500
```

If **`logread`** has firewall lines but Live View does not, check LuCI login and that **`luci-app-fwlive`** is installed. If **`logread`** is empty, fix logging on the router first. The UI cannot invent events.

---

## See also

Deep configuration lives in the reference files:

- **[fwlive-nft-logging.md](../fwlive-nft-logging.md)** — kernel `nf_log` modules, Docker caveats, custom chains, rule-level logging, prefix pitfalls.
- **[fwlive-iptables-logging.md](../fwlive-iptables-logging.md)** — iptables / fw3 (21.02.x) LOG reference.
- **[Using the UI](using-the-ui.md)** — the empty state and watch-strip controls.

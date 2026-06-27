# iptables / fw3 LOG reference (best-effort)

Firewall Live View reads **logd** — the same pipeline as fw4. On iptables backends, traffic appears only when rules use **`-j LOG`** or UCI **`option log '1'`**.

**This is not iptables TRACE.** Silent rule hits without LOG never appear in the table.

**Support:**

- **21.02.x (legacy fw3):** iptables LOG is the **primary** path — lab-validated on 21.02.7 x86. Install the **21.02 SDK-built ipk** only.
- **22.03.x / 23.05+:** **firewall4/nft** is the supported path; **iptables LOG** is best-effort when `/usr/sbin/iptables` is present without nft.

**This is not iptables TRACE.** Silent rule hits without LOG never appear in the table.

See also: [nft/fw4 logging](fwlive-nft-logging.md) · [enabling logs (user)](../user/enabling-firewall-logs.md)

## Quick lab test

```sh
./scripts/fwlive-iptables-ping-log.sh add --ssh
ping -c 3 $(./scripts/fwlive-iptables-ping-log.sh guest-ip)
./scripts/fwlive-ubus-read.sh --lines 20
./scripts/fwlive-iptables-ping-log.sh remove --ssh
```

## Manual rule example

```sh
iptables -I INPUT -p icmp --icmp-type echo-request \
  -j LOG --log-prefix "fwlive-ping: "
iptables -I INPUT -p icmp --icmp-type echo-request -j ACCEPT
```

Verify with `logread | grep fwlive-ping` before expecting LuCI rows.

UCI: `option log '1'` on a `@rule` or wan zone where your image supports it.

## LuCI UI

When the router backend is iptables, the page shows a short **`iptables`** label (vs **`fw4`** for nft). Rule links open **Status → Firewall** (iptables view).

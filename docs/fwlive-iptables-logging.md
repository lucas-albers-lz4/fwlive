# LOG metadata and historical iptables reference

On supported OpenWrt releases, Firewall Live View reads **logd** from the
firewall4/nft pipeline. Traffic appears only when rules use nft logging or UCI
**`option log '1'`**. Log lines tagged `iptables` (including `iptables-nft`
and `xt_LOG`) still classify, but they do not select an iptables rules-map
path.

**This is not iptables TRACE.** Silent rule hits without LOG never appear in the table.

**Support:**

- **Supported releases (23.05+):** **firewall4/nft** is the rules-map path.
- **21.02.x / 22.03.x:** unsupported. The iptables/fw3 material below is a historical lab note only — there is no published feed or SDK matrix cell. See [supported releases](supported-releases.md#2102x-historical).

See also: [nft/fw4 logging](fwlive-nft-logging.md) · [enabling logs (user)](user/enabling-firewall-logs.md)

## Quick start on supported releases

Use the [User guide → Quick start](user/enabling-firewall-logs.md#quick-start-after-install)
for the supported nft/fw4 path. The app is a LOG viewer, not an iptables or
nftables TRACE viewer; silent rule hits do not appear in the table.

## Historical fw3 / iptables lab note

The commands in this section apply only to the retired 21.02 fw3 lab. They are
not a current support or validation path.

```sh
./scripts/fwlive-iptables-ping-log.sh add --ssh
ping -c 3 $(./scripts/fwlive-iptables-ping-log.sh guest-ip)
./scripts/fwlive-ubus-read.sh --lines 20
./scripts/fwlive-iptables-ping-log.sh remove --ssh
```

### Manual rule example (historical)

The copy-pasteable `iptables -j LOG` snippet below is for that retired fw3 lab
only. On supported 23.05+ images, use nft/UCI logging instead.

```sh
iptables -I INPUT -p icmp --icmp-type echo-request \
  -j LOG --log-prefix "fwlive-ping: "
iptables -I INPUT -p icmp --icmp-type echo-request -j ACCEPT
```

Make sure that `logread | grep fwlive-ping` shows lines before expecting LuCI rows.

UCI: `option log '1'` on a `@rule` or wan zone where your image supports it.

## Current LuCI UI

On supported releases, the page shows **`using fw4`** for the firewall4/nft
backend. Rule-name links use `admin/network/firewall/rules`; there is no
iptables-save rules-map fallback. An iptables-tagged log can still classify,
and a registered legacy table may add a diagnostic warning, but neither
changes the supported rules-map contract.

# Enabling firewall logs

Firewall Live View only shows traffic that **nftables / fw4** writes to the system log. A rule must include **`log`** (and typically `accept` or `drop`) for hits to appear.

## Quick test — ICMP ping

Insert a temporary rule at the **top** of the `input` chain so LAN traffic is not skipped by `jump input_lan`:

```sh
nft insert rule inet fw4 input ip protocol icmp icmp type echo-request \
  log prefix "fwlive-ping " accept
```

Generate traffic:

```sh
ping -c 5 127.0.0.1
```

Verify:

```sh
logread | grep fwlive-ping
```

Open **Firewall Live View** — you should see pass events with rule hint `fwlive-ping`.

Remove when finished:

```sh
nft delete rule inet fw4 input handle <handle>
# or list handles: nft -a list chain inet fw4 input
```

## Lab helper script (QEMU / SSH)

From a machine that can SSH to the router:

```sh
./scripts/fwlive-nft-ping-log.sh add --ssh
ssh -p 2222 root@127.0.0.1 'ping -c 5 127.0.0.1'   # QEMU example
```

## Production rules

For real policies, add `log` to the **specific** fw4 rule you are debugging — via UCI (`/etc/config/firewall`) or `nft` directly. Examples:

- Log new WAN input drops
- Log forwarded traffic on a guest network
- Log traffic hitting a DNAT redirect

**Caution:** verbose logging on busy rules can fill logd quickly. Use prefixes (e.g. `log prefix "guest-drop "`) so filters in the UI stay useful.

## UCI / fw4 notes

- Rules **appended** to `input` may never see LAN packets due to `jump input_lan` — prefer **insert** for tests or attach log on the zone chain you care about.
- IPv6 uses separate chains; add `ip6` / `icmpv6` rules if you need v6 visibility.

## Full reference

Advanced scenarios, Docker lab, and IPv6: **[`../fwlive-nft-logging.md`](../fwlive-nft-logging.md)**

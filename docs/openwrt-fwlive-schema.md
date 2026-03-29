# OpenWrt Firewall Live Event Schema (24.10 / nftables)

**See also:** [OPNsense vs OpenWrt — logging-centric understanding](opnsense-liveview-understanding.md) · [OPNsense UI/API parity matrix](opnsense-liveview-parity.md)

## Package location

Shipped as feed package [`openwrt-feed/luci-app-fwlive`](../openwrt-feed/luci-app-fwlive/Makefile); see [`openwrt-feed/README.md`](../openwrt-feed/README.md) for `feeds.conf` / `src-link` integration.

## Source

- Primary source: ubus `log.read` entries from `logd`.
- Input format: log message text containing nftables/kernel key-value segments such as `IN=`, `OUT=`, `SRC=`, `DST=`, `PROTO=`, `SPT=`, `DPT=`.

## Normalized event

- `id`: deterministic key for dedupe and stable row identity.
- `timestamp`: ISO timestamp from log entry time.
- `action`: detected action token (`ACCEPT`, `DROP`, `REJECT`, etc.), or `UNKNOWN`.
- `interface`: `IN` or `OUT` value.
- `direction`: `in`, `out`, `forward`, or `unknown`.
- `proto`: upper-cased `PROTO`.
- `src`: source IP.
- `sport`: source port.
- `dst`: destination IP.
- `dport`: destination port.
- `message`: original unmodified log message.

## Retention and query model

- History cap: 2000 entries in browser memory.
- View cap: last 200 filtered rows rendered.
- Update interval: 1 second poll cadence.
- Filter model: client-side predicates over normalized rows.

# OpenWrt Firewall Live Event Schema (24.10 / nftables)

**See also:** [OPNsense vs OpenWrt — logging-centric understanding](opnsense-liveview-understanding.md) · [OPNsense UI/API parity matrix](opnsense-liveview-parity.md)

## Package location

Shipped as feed package [`openwrt-feed/luci-app-fwlive`](../openwrt-feed/luci-app-fwlive/Makefile); see [`openwrt-feed/README.md`](../openwrt-feed/README.md) for `feeds.conf` / `src-link` integration.

## Source

- Primary source: ubus `log.read` entries from `logd`.
- **Stage 1 filter:** only lines matching `isFirewallEvent()` are shown (see [`core/fwlive-log.js`](../core/fwlive-log.js)); generic syslog noise is dropped.
- Input format: log message text containing nftables/kernel key-value segments such as `IN=`, `OUT=`, `SRC=`, `DST=`, `PROTO=`, `SPT=`, `DPT=`.
- Requires fw4/nft rules with **`log`** for traffic to appear — [`fwlive-nft-logging.md`](fwlive-nft-logging.md).

## Normalized event (stage 2)

- `id`: deterministic key for dedupe and stable row identity.
- `timestamp`: **Unix epoch seconds** (integer) from log entry time.
- `timestamp_display`: ISO-8601 in normalized JSON; LuCI renders local `YYYY-MM-DD HH:MM:SS` via `formatTimestampLocal()`.
- `action`: normalized enum: `pass`, `block`, `drop`, `reject`, or `unknown`.
- `action_raw`: original token from the log line (`ACCEPT`, `DROP`, …).
- `rule_hint`: tag parsed from log prefix / nft `log prefix` (e.g. `fwlive-ping`, `fw4`, `fwlive-test`); empty when unknown.
- `rule_label`: display label derived from `rule_hint` (UCI name resolve deferred to stage 3.4+).
- `interface`: `IN` or `OUT` (legacy convenience).
- `interface_in` / `interface_out`: from `IN=` / `OUT=`.
- `direction`: `in`, `out`, `forward`, or `unknown`.
- `proto`: upper-cased `PROTO`.
- `src`, `sport`, `dst`, `dport`: 5-tuple fields.
- `flags`: TCP flag text (`SYN`, `SYN,ACK`, …) or `TCPFLAGS=` / `FLAGS=` when present.
- `length`: packet length from `LEN=` when present (integer, else `null`).
- `message`: original unmodified log message.

## Retention and query model

- History cap: user **Limit** dropdown (25…2000, default 100); stored in browser `localStorage`.
- View cap: same as history limit (all buffered rows may render after filters).
- Update interval: 1 second poll cadence.
- Filter model: client-side predicates over normalized rows.

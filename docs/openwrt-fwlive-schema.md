# OpenWrt Firewall Live Event Schema (fw4 / nftables)

Applies to **23.05+** images using firewall4/nft (primary path). Log lines tagged `iptables` still classify; OpenWrt **21.02** / **22.03** are unsupported — see [iptables logging reference](fwlive-iptables-logging.md). Examples below were tested on **24.10.8**; field availability may vary by release and image profile.

**See also:** [OPNsense UI/API parity matrix](opnsense-liveview-parity.md)

## Package location

Shipped as feed package [`openwrt-feed/luci-app-fwlive`](../openwrt-feed/luci-app-fwlive/Makefile); see [`openwrt-feed/README.md`](../openwrt-feed/README.md) for `feeds.conf` / `src-link` integration.

## Source

- Primary source: ubus `fwlive poll` (filtered `log.read` entries from `logd`; line count in `addresses[0]`).
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
- `rule_label`: display label derived from `rule_hint` (UCI name resolve via `ubus fwlive rules`).
- `interface`: `IN` or `OUT` (legacy convenience).
- `interface_in` / `interface_out`: from `IN=` / `OUT=`.
- `direction`: `in`, `out`, `forward`, or `unknown`.
- `proto`: upper-cased `PROTO`.
- `src`, `sport`, `dst`, `dport`: 5-tuple fields.
- `flags`: TCP flag text (`SYN`, `SYN,ACK`, …) or `TCPFLAGS=` / `FLAGS=` when present.
- `length`: packet length from `LEN=` when present (integer, else `null`).
- `message`: original unmodified log message.

## Fetch budget and adaptive metadata

- The browser's **Auto** fetch budget is `min(max(Limit × 4, 100), 2000)` for
  live polls. **Manual** uses one of 25, 50, 100, 250, 500, 1000, or 2000 raw
  lines per fetch. Manual does not disable server protection or client cadence
  backoff; paused Auto retains the compatibility 2000-line request, while
  paused Manual uses its selected maximum.
- `adaptive: 1` means the server adaptive controller is active; `adaptive: 0`
  explicitly reports it disabled. An omitted or malformed value is unknown and
  must not be presented as confirmed protection state.
- Successful adaptive replies may include `effective_limit`, the integer raw
  line limit actually passed to the log source (1…2000). It is omitted from
  adaptive-off replies and all error replies. `shed.limit` is state metadata,
  not a substitute for `effective_limit`.
- `messages_received` is the pre-filter count of raw `log.read` entries. The
  returned message count in the UI is `reply.log.length` after classification
  and before client deduplication; it is not a raw-line count or a displayed
  row count.
- The log source is a finite ring. A successful poll cannot guarantee that
  older entries still exist, and fwlive does not change forwarding behavior or
  recover entries already evicted by the router.

## Retention and query model

- History cap: user **Limit** dropdown (25…2000, default 100); stored in browser `localStorage`.
- View cap: same as history limit on stronger devices; a router-reported weak
  device caps browser rendering at 250 rows while retaining the selected
  buffer limit.
- Update interval: starts at a 1-second cadence, then Layer 2 RTT hysteresis
  may use 2- or 5-second cadence. Native hidden tabs pause polling and resume
  with one catch-up poll.
- Filter model: client-side predicates over normalized rows.

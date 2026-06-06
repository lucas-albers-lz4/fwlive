# OPNsense Live View vs OpenWrt — logging-centric understanding

This document is the **in-repo** counterpart to planning notes about how OPNsense’s **Live View** relates to this project. It stays in git so GitHub readers see the same story as local Cursor plans.

**Related:** [OPNsense parity matrix (UI/API)](opnsense-liveview-parity.md) · [OpenWrt event schema](openwrt-fwlive-schema.md) · [staged plan](fwlive-development-plan.md) · logic [`core/fwlive-log.js`](../core/fwlive-log.js) / LuCI [`fwlive/log.js`](../openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js)

## Why this exists

We want **correct behavior** on OpenWrt without chasing the wrong abstraction: the useful comparison is **what appears in firewall logs**, not a PF-vs-nft rule translation.

## PF vs nft — only logging matters for the UI

| Layer | OPNsense | OpenWrt (this project) |
| ----- | -------- | ---------------------- |
| Packet filter | PF | nftables + fw4 |
| **What the UI should depend on** | **Structured firewall log lines** (however PF emits them) | **Structured lines from nft `log`** → kernel printk/syslog → **logd** → `ubus log.read` |

OPNsense does not expose raw PF state to Live View in a portable way. The contract is **log events** (time, action, interfaces, 5-tuple, etc.). On OpenWrt we normalize **key=value** segments in the message text (`IN=`, `OUT=`, `SRC=`, `DST=`, …), per the schema doc and parser above.

## What is already documented

- **UI/API parity (OPNsense):** [opnsense-liveview-parity.md](opnsense-liveview-parity.md) — polling endpoint, ~1s refresh, filters, deferred streaming/DNS, etc.
- **Data path (OpenWrt):** [openwrt-fwlive-schema.md](openwrt-fwlive-schema.md) — `log.read`, normalized fields, caps.

## Confidence (for prioritization)

**Higher — enough for MVP / “inspired by OPNsense”**

- UX: poll-based table, quick search, column filters, deny vs allow styling — see parity doc and LuCI code.
- OpenWrt: events come from rules that use **`log`**; parser expects Linux netfilter-style `KEY=value` tokens in the log message.

**Medium — optional deep dive**

- **OPNsense server pipeline:** Full trace from PF logging (pflog, filterlog, plugins) to JSON from `/api/diagnostics/firewall/log` is **not** specified line-by-line in this repo; parity work here is **UI/API level**, not a PF log grammar.
- **Digest / incremental fetch:** OPNsense may use `digest` + `limit`; our LuCI path uses full `log.read` polls — acceptable for MVP.

**When to dig into OPNsense source (`opnsense/core`)**

- Column-level parity (rule labels, tracker IDs, TCP flags) depends on PF-specific log fields.
- Server-side filter operators must match OPNsense.
- Debugging “OPNsense shows X, OpenWrt shows Y” where the cause is **log format**, not missing **`log`** on nft rules.

### Optional research checklist

1. Find API handlers for `diagnostics/firewall/log` (e.g. `FirewallLog`, `filterlog`).
2. Document raw log line shape before JSON (syslog facility, prefixes).
3. Compare one PF/pflog-derived row to one nft log line after normalization (same conceptual columns).
4. Record deliberate differences in [opnsense-liveview-parity.md](opnsense-liveview-parity.md) or here — do not duplicate upstream PF manuals.

## Non-goals

- Replicating PF rule syntax or OPNsense’s exact PHP/API payload unless product requirements demand it.
- Treating “plan milestones complete” as “every PF detail traced” — see confidence section above.

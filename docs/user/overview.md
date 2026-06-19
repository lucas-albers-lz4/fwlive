# What is Firewall Live View?

**Firewall Live View** is a LuCI page for OpenWrt that shows **live firewall log events** in a sortable, filterable table — similar in spirit to OPNsense’s Live View, built for **nftables / firewall4**.

## The problem it solves

On OpenWrt, firewall hits are written to the system log (`logread`). That stream mixes dnsmasq, procd, kernel noise, and firewall lines. Troubleshooting “why was this packet dropped?” usually means:

- SSH in and run `logread | grep …`
- Lose context when the terminal scrolls
- Repeat the same grep with different filters

Firewall Live View gives operators a **dedicated, always-on table** that:

- Refreshes about **once per second**
- Shows **only firewall-shaped lines**
- Highlights **pass** vs **drop** (and related actions)
- Supports **field filters**, quick search, and **click-to-filter**
- Resolves **rule names** where fw4/nft metadata allows
- Keeps filter state in the **URL hash** so you can bookmark or share a view

## What it is not

- Not a packet capture tool (use `tcpdump` for full payloads)
- Not a replacement for `nft list ruleset` — it shows **what already logged**
- Not tied to one router model — the package is architecture-independent (`_all` / LuCI JS)

## How data flows

```mermaid
flowchart LR
  A[nftables / fw4 rule with log] --> B[kernel log]
  B --> C[logd]
  C --> D["ubus fwlive poll"]
  D --> E[LuCI Firewall Live View]
  E --> F[Parse, filter, render table]
```

`fwlive poll` wraps filtered `log.read` — only firewall-shaped lines are sent to the browser.

Traffic only appears when your firewall rules include **`log`** (or equivalent) for the traffic you care about. See [Enabling firewall logs](enabling-firewall-logs.md).

## When to use it

| Scenario | Useful? |
|----------|---------|
| Debug a new port-forward or WAN rule | Yes — watch pass/drop in real time |
| Confirm guest/Wi‑Fi isolation | Yes — filter by interface and source |
| Audit intermittent drops | Yes — pause the table, adjust filters, resume |
| Long-term archival / compliance | No — use remote syslog or dedicated logging |

## Next steps

1. Check [Requirements](requirements.md)
2. [Install](installation.md) the package
3. [Enable logging — quick start](enabling-firewall-logs.md#quick-start-after-install) (WAN drops or ping test; stock images log nothing by default)
4. Open **Status → Firewall Live View** and read [Using the UI](using-the-ui.md)

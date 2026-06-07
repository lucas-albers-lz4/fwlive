# Using the UI

Open **Status → Firewall Live View** in LuCI.

The page loads **live firewall traffic immediately** — no setup when your firewall already logs events. **Simple** is the default layout; use **Show Detail** in the toolbar when you need the full forensic table.

On-page **Help** (collapsed at the bottom) covers the basics without leaving the router.

## Simple view (default)

![Simple view — compact table](assets/fwlive-simple-view.png)

A compact table focused on what operators scan most often:

| Column | Meaning |
|--------|---------|
| **Action** | pass, drop, reject, etc. — color-coded |
| **Time** | Compact `HH:MM:SS` (today) |
| **Interface** | Ingress interface (badge) |
| **Flow** | `source:port → destination:port` — click parts to filter |
| **Proto** | TCP, UDP, ICMP, … |
| **Rule** | Resolved fw4/UCI name when possible |

**Expand raw message:** click any data row (not a filter link) to show or hide the full netfilter log line below that row.

![Expanded message row](assets/fwlive-expanded-message.png)

### Simple filters

Quick search, **Action**, and **Protocol** are always visible. Open **More filters** for interface, source/destination, and ports.

![Filters and chips](assets/fwlive-filters.png)

## Detailed view

Click **Show Detail** in the toolbar. Click **Hide Detail** to return to Simple.

![Detailed view — all columns](assets/fwlive-main-view.png)

Shows every normalized field in one wide table:

Time, Action, Rule, IN, OUT, Dir, Proto, Source, SPort, Destination, DPort, Flags, Len, **Message**

Use Detailed when you need the raw `KEY=value` message inline without expanding rows, or when debugging flags, length, and direction fields.

The **Message: wrap / one-line** toolbar control applies in Detailed view only.

## Shared controls

| Control | Behavior |
|---------|----------|
| **Auto-refresh** | When checked, the table updates each poll (~1s). Uncheck to freeze the display while polling continues. |
| **Limit** | Rows to keep (25 … 2000, default 100). Stored in the browser. |
| **Show Detail / Hide Detail** | Toggles Simple ↔ Detailed; preference saved in `localStorage` after you use it. |
| **Quick search** | Matches across all normalized fields. |

## Filtering

- **Click any cell** (action, IP, protocol, interface, flow endpoint) to filter.
- Active filters appear as **chips** — remove one or clear all.
- Prefix text filters with **`!`** for negation.
- **URL hash** stores filters, limit, and `view=detailed` for shareable links.

### Filter tips

| Goal | Approach |
|------|------------|
| See only drops | Action → `drop` |
| One client | Click source in **Flow** or use **More filters → Source** |
| ICMP test | Protocol `icmp` after [enabling ping logging](enabling-firewall-logs.md) |

## Rule column

When fw4 logs a **prefix** (e.g. `fwlive-ping `), the UI shows a label. Ctrl+click (Cmd+click on macOS) a rule name to open firewall settings; plain click filters on that hint.

## Empty table

If no events appear, the page shows an on-router hint: traffic needs **`log`** on fw4/nft rules. A link to **Network → Firewall** is provided. Logged WAN drops and similar traffic should appear without any configuration on this page.

## High traffic rate

If more than ~250 **new** events arrive per second, a banner may appear and rendering throttles briefly.

## Related reading

- [Overview](overview.md)
- [Enabling firewall logs](enabling-firewall-logs.md)

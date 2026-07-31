# Using the UI

Open **Status → Firewall Live View** in LuCI.

The page loads **live firewall traffic immediately** — no setup when your firewall already logs events. **Simple** is the default layout; use **Show Detail** on the watch strip when you need the full forensic table.

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

Click **Show Detail** on the watch strip. Click **Hide Detail** to return to Simple.

![Detailed view — all columns](assets/fwlive-main-view.png)

Shows every normalized field in one wide table:

Time, Action, Rule, IN, OUT, Dir, Proto, Source, SPort, Destination, DPort, Flags, Len, **Message**

Use Detailed when you need the raw `KEY=value` message inline without expanding rows, or when debugging flags, length, and direction fields.

The **Message: wrap / one-line** control (next to Show Detail) applies in Detailed view only.

## Shared controls

| Control | Behavior |
|---------|----------|
| **Pause / Resume** | Live updates run until you Pause. Resume continues the table; polling never stops. |
| **Enable logging** | Filled button on the watch strip when WAN logging is off. When on, a quiet **WAN logging on** control disables it. Mutates firewall UCI and reloads — no confirm step. Concurrent toggles from multiple admins are last-writer-wins. Rate is the firewall `log_limit` (default `10/minute`), not a fwlive cap. |
| **Show Detail / Hide Detail** | Toggles Simple ↔ Detailed; preference saved in `localStorage` after you use it. |
| **Display options** | Closed by default. Holds **Limit**, **Row tint** / palette, **Show hostnames**, and **Chip style**. |
| **Limit** | Rows to keep (25 … 2000, default 100). Stored in the browser. |
| **Show hostnames** | Off by default. When checked, resolved names replace IPs in **Flow** and address columns; hover shows the IP. Click still filters by IP. |
| **Quick search** | Matches across all normalized fields. |

## Filtering

- **Click any cell** (action, IP, protocol, interface, flow endpoint) to filter.
- Active filters appear as **chips** — click **≠** on a chip to flip include ↔ exclude; **×** removes one; **Clear all** resets.
- You can also prefix text filters with **`!`** for negation (same as **≠** on a chip).
- **URL hash** stores filters, limit, and `view=detailed` for shareable links.

### Filter tips

| Goal | Approach |
|------|------------|
| See only drops | Action → `drop` |
| Hide passes | Click **pass** in the table, then **≠** on the `action: pass` chip |
| One client | Click source in **Flow** or use **More filters → Source** |
| ICMP test | Protocol `icmp` after [enabling ping logging](enabling-firewall-logs.md) |

## Rule column

When fw4 logs a **prefix** (e.g. `fwlive-ping `), the UI shows a label. Ctrl+click (Cmd+click on macOS) a rule name to open firewall settings; plain click filters on that hint.

## Empty table

If no events appear, use **Enable logging** on the page (sets WAN zone `log=1` — same as **Network → Firewall**). The empty state explains what will and will not appear (WAN drops/rejects, not normal LAN browsing). If custom rule logs are already visible, use the toolbar logging control instead.

If logging is already on but the table is still empty, wait for inbound WAN traffic or see **[Quick start — optional ping test](enabling-firewall-logs.md#3-optional--confirm-the-ui-with-a-ping-synthetic-pass-events)**. Advanced setup: **[Enabling firewall logs](enabling-firewall-logs.md)**.

## High traffic rate

If more than ~250 **new** events arrive per second, a banner may appear and rendering throttles briefly.

## Related reading

- [Overview](overview.md)
- [Enabling firewall logs](enabling-firewall-logs.md)

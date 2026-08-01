# User guide — Firewall Live View

Documentation for **installing and using** `luci-app-fwlive` on an OpenWrt router.

| Guide | What you'll learn |
|-------|-------------------|
| [Overview](overview.md) | What the package does and when to use it |
| [Requirements](requirements.md) | Supported OpenWrt versions and dependencies |
| [Installation](installation.md) | Binary feed (recommended), GitHub Release, or `src-link` feed |
| [Using the UI](using-the-ui.md) | First visit, Simple & Detailed views, Show Detail, Help |
| [Enabling firewall logs](enabling-firewall-logs.md) | Quick start after install, zone/rule logging, log more traffic |

**Menu path after install:** **Status → Firewall Live View**  
(`http://<router>/cgi-bin/luci/admin/status/fwlive`)

Live View shows **whatever OpenWrt is logging**. Stock configs log almost nothing — use **Enable logging** once for WAN drops/rejects.

---

## Screenshots (from QEMU lab)

| First visit — logging off | After Enable |
|---------------------------|--------------|
| ![Empty — logging off](assets/fwlive-empty-logging-off.png) | ![After Enable](assets/fwlive-after-enable.png) |

| Simple (default) | Detailed (Show Detail) |
|------------------|------------------------|
| ![Simple view](assets/fwlive-simple-view.png) | ![Detailed view](assets/fwlive-main-view.png) |

| Filters | Expanded message (Simple) |
|---------|---------------------------|
| ![Filters](assets/fwlive-filters.png) | ![Expanded row](assets/fwlive-expanded-message.png) |

Walkthrough: [Using the UI → First visit](using-the-ui.md#first-visit). Recapture: [assets/capture-screenshots.md](assets/capture-screenshots.md).

---

## Developer?

Building, testing, or contributing: **[Developer documentation](../developer/README.md)**.

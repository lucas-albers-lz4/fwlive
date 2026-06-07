# luci-app-fwlive

LuCI **Firewall Live View** — client-side JS view polling `ubus fwlive poll` (firewall-only log lines), with rule labels via `fwlive rules` and optional reverse DNS via `fwlive resolve`.

## Package layout (OpenWrt / LuCI conventions)

| Path | Role |
|------|------|
| `Makefile` | `LUCI_TITLE`, `LUCI_DEPENDS`, includes `luci.mk` |
| `htdocs/luci-static/resources/view/status/fwlive.js` | LuCI view (`view.extend`) |
| `htdocs/luci-static/resources/fwlive/log.js` | Parser/filter module (mirror of repo `core/fwlive-log.js`) |
| `root/usr/share/luci/menu.d/*.json` | Menu entry (`admin/status/fwlive`) |
| `root/usr/share/rpcd/acl.d/*.json` | ubus ACL (`fwlive.rules`, `fwlive.poll`, `fwlive.resolve`) |
| `root/usr/libexec/rpcd/fwlive` | rpcd plugin (`rules`, `poll`, `resolve`) |
| `root/usr/libexec/fwlive-log-filter.sh` | Server-side firewall-only filter (`isFirewallEvent` parity) |
| `root/usr/libexec/fwlive-is-firewall-event.sh` | Shared filter logic (sourced by filter + tests) |

No `luasrc/` — modern JS-only app. No `po/` until translations are requested.

## Dependencies

- `luci-base`, `logd`, `rpcd`, `firewall4` (nft/fw4)
- Menu depends on executable `/usr/sbin/nft`

## Documentation

- **Users:** [`../../docs/user/installation.md`](../../docs/user/installation.md)
- **Developers:** [`../../docs/developer/README.md`](../../docs/developer/README.md)

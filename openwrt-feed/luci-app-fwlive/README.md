# luci-app-fwlive

LuCI **Firewall Live View** — client-side JS view polling `ubus log.read`, with optional rule labels via `ubus fwlive rules`.

## Package layout (OpenWrt / LuCI conventions)

| Path | Role |
|------|------|
| `Makefile` | `LUCI_TITLE`, `LUCI_DEPENDS`, includes `luci.mk` |
| `htdocs/luci-static/resources/view/status/fwlive.js` | LuCI view (`view.extend`) |
| `htdocs/luci-static/resources/fwlive/log.js` | Parser/filter module (mirror of repo `core/fwlive-log.js`) |
| `root/usr/share/luci/menu.d/*.json` | Menu entry (`admin/status/fwlive`) |
| `root/usr/share/rpcd/acl.d/*.json` | ubus ACL (`log.read`, `fwlive.rules`) |
| `root/usr/libexec/rpcd/fwlive` | rpcd plugin (`list` / `call`) |

No `luasrc/` — modern JS-only app. No `po/` until translations are requested.

## Dependencies

- `luci-base`, `logd`, `rpcd`, `firewall4` (nft/fw4)
- Menu depends on executable `/usr/sbin/nft`

## Build

See [`../../docs/dev-environment.md`](../../docs/dev-environment.md) and [`../README.md`](../README.md).

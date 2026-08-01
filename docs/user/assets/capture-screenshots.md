# Capturing Firewall Live View screenshots

Repeatable steps for updating images in this directory from the QEMU x86 lab.

## Prerequisites

- Linux host with QEMU, Docker SDK build (optional), Node.js
- Playwright (one-time): `npm install` then `npx playwright install chromium`

## Lab setup

```sh
./scripts/run-openwrt-x86-qemu.sh --stop
cp /usr/share/OVMF/OVMF_VARS_4M.fd lab/images/OVMF_VARS_4M.fd
OWRT_RELEASE=24.10.5 ./scripts/run-openwrt-x86-qemu.sh
MAX_WAIT=300 ./scripts/qemu-wait-guest.sh
OWRT_FWLIVE_VERSION=24.10.5 ./scripts/qemu-install-fwlive.sh
```

**Do not** add the ping LOG helper yet — shot 1 needs logging off / empty table.

LuCI: http://localhost:8080/cgi-bin/luci/admin/status/fwlive (login: `root`, empty password)

Clear browser consent for a true first visit (the capture script clears `fwlive-logging-consent-v1`).

## Automated capture

```sh
node scripts/capture-fwlive-screenshots.mjs
```

Order of operations inside the script:

1. Open Live View with WAN logging off → `fwlive-empty-logging-off.png` (consent visible)
2. Click Enable → `fwlive-after-enable.png`
3. Install ping LOG helper + generate traffic → Simple / filters / expand / Detail shots

Writes:

| File | Content |
|------|---------|
| `fwlive-empty-logging-off.png` | First visit — logging off + consent |
| `fwlive-after-enable.png` | Notice + **WAN logging on** |
| `fwlive-simple-view.png` | Simple view with filter active |
| `fwlive-expanded-message.png` | Simple view, one row expanded (Message) |
| `fwlive-filters.png` | Filter bar + chips crop |
| `fwlive-main-view.png` | Detailed view (all columns) |
| `fwlive-dark-mode.png` | Optional — not in the user gallery |

## Manual capture

Use the same lab URL. Capture empty/consent **before** Enable. After Enable, capture the notice strip. Then add traffic (`./scripts/fwlive-nft-ping-log.sh add --ssh` and ping) for the remaining shots. Click **Show Detail** for `fwlive-main-view.png`. In Simple view, click a row (not a filter link) to expand the message for `fwlive-expanded-message.png`.

After installing or changing `menu.d`, clear the guest cache if the page 404s:

```sh
ssh -p 2222 root@127.0.0.1 'rm -f /tmp/luci-indexcache; /etc/init.d/uhttpd restart'
```

`qemu-install-fwlive.sh` syncs the menu entry and clears the cache automatically.

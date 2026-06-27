# OpenWrt 21.02 Compatibility (fw3 / iptables)

## Status

**Supported (legacy)** on OpenWrt **21.02.7** with the same `luci-app-fwlive` `_all` ipk built from the **21.02 SDK**.

| Check | Result (lab, 2026-06-20) |
|-------|--------------------------|
| SDK build (`x86-64` / 21.02) | Pass |
| `ubus log.read` / `ubus fwlive poll` | Pass |
| `ubus fwlive rules` (iptables-save + UCI) | Pass — backend `iptables` |
| LuCI dispatcher + static JS | Pass (HTTP 403 login required) |
| iptables ping log → parsed rows | Pass |
| Custom chain LOG (`fwlive-custom:` prefix) | Pass |
| x86_64 QEMU smoke (`validate-openwrt.sh --version 21.02`) | Pass |
| LuCI GUI (manual / curl login, 2026-06-20) | Pass — menu page loads, `fwlive.js` served, `using iptables` in view source; poll rows after ping-log |

**Install:** signed opkg feed at `https://lucas-albers-lz4.github.io/fwlive-packages/21.02` — see [binary feed](binary-feed.md#openwrt-2102x-opkg-legacy-fw3). GitHub Release `.ipk` must be the **21.02-built** artifact (not 23.05+).

**Important:** Do not install a 23.05+ feed package on 21.02 — use the **21.02** feed channel or SDK-built ipk only.

**Validation depth:** App stack sign-off on **21.02.7 x86-64 QEMU lab** only. Typical fw3 fleets use MIPS/ARM — treat other SoCs as best-effort until hardware or armsr lab is run.

OpenWrt **21.02 is EOL** — support is for operators stuck on fw3, not a recommended baseline. **22.03+ uses firewall4 (nft)** — see [22.03 compat](openwrt-22.03-compat.md) and [requirements](user/requirements.md).

## Build

```sh
./scripts/docker-sdk.sh build --target x86-64 --version 21.02
# ipk: out/x86_64/21.02.7/fwlive/luci-app-fwlive_*_all.ipk
```

## Lab validation (quick)

```sh
./scripts/validate-openwrt.sh --version 21.02 --sdk-target x86-64
```

Ensure no other QEMU instance holds the disk image before prepare (script stops QEMU between runs).

### Manual steps

```sh
RELEASE=21.02.7 ./scripts/download-openwrt-x86-64.sh
sudo OWRT_IMG=lab/images/openwrt-x86-64-21.02.7.img ./scripts/qemu-lab-prepare-image.sh
OWRT_RELEASE=21.02.7 OWRT_QEMU_SERIAL_SOCKET=1 ./scripts/run-openwrt-x86-qemu.sh &
./scripts/qemu-wait-guest.sh
OWRT_FWLIVE_VERSION=21.02.7 ./scripts/qemu-install-fwlive.sh
./scripts/fwlive-iptables-ping-log.sh add --ssh
./scripts/qemu-smoke-fwlive.sh
```

LuCI: `http://localhost:8080/cgi-bin/luci/admin/status/fwlive` (login required on stock images).

## 21.02-specific lab notes

1. **LuCI dispatcher** — 21.02 uses **lua_prefix** (no ucode dispatcher). `qemu-lab-prepare-image.sh` skips ucode tweaks when `dispatcher.uc` is absent.

2. **LAN proto=dhcp** — Required for slirp user-net hostfwd. Prepare script sets `network.lan.proto=dhcp`. Re-run prepare if a previous QEMU run left the image with static LAN.

3. **Log format** — fw3 LOG lines appear as **`kern.warn kernel:`** with netfilter KV fields (not always `iptables:` tag). Parser handles both; see `tests/fixtures/logread-iptables.json`.

4. **Rule admin link** — iptables backend links to `admin/status/iptables` (verified reachable on 21.02.7).

5. **Background QEMU** — Use `OWRT_QEMU_SERIAL_SOCKET=1` when starting QEMU in the background (validate matrix sets this automatically).

## Operator enablement (#7)

fwlive shows traffic that hits **`-j LOG`** rules — not TRACE. On custom chains:

```sh
iptables -N my-debug
iptables -A my-debug -j LOG --log-prefix "my-chain: "
iptables -A my-debug -j ACCEPT
iptables -I INPUT -p icmp --icmp-type echo-request -j my-debug
```

UCI: `option log '1'` on `@rule` entries where supported.

## Acceptance

See [fwlive-acceptance.md](fwlive-acceptance.md) and GitHub issue [#7](https://github.com/lucas-albers-lz4/fwlive/issues/7).

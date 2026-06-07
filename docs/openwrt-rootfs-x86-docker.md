# OpenWrt x86_64 experiment (Docker LuCI)

Use this to **debug web/SSH reachability** on your desktop without QEMU slirp/hostfwd. It uses the **official** [`ghcr.io/openwrt/rootfs:x86-64`](https://github.com/openwrt/docker) image (OpenWrt **SNAPSHOT**, `x86/64`).

This is **not** the production test target for **fwview** (`armsr` / `armv8`). It is a fast loop for “can we see LuCI in a browser?” and UCI/firewall experiments.

**Why Docker (not QEMU/Vagrant/LXD here):** the official `rootfs` image is built for container CI; it boots in seconds, publishes ports directly to the host, and avoids slirp subnet / NIC-order bugs we hit on armsr QEMU.

## Quick start

```sh
./scripts/run-openwrt-x86-experiment.sh
```

Then open **[http://127.0.0.1:8080/cgi-bin/luci/](http://127.0.0.1:8080/cgi-bin/luci/)** — login **`root`** (empty password unless you set one).

```sh
./scripts/run-openwrt-x86-experiment.sh --fresh   # wipe + recreate container
./scripts/run-openwrt-x86-experiment.sh --stop    # remove container
```

- **SSH:** `ssh -p 2222 root@127.0.0.1`
- **Bootstrap only** (container already running): `./scripts/docker-rootfs-x86-bootstrap.sh`

## Why QEMU was harder

| Issue | QEMU `user` netdev | Docker `rootfs` |
|-------|-------------------|-----------------|
| Guest LAN IP | Must match slirp subnet (`net=…` on `-netdev user`) | Must match Docker bridge IP (`172.17.0.x`) |
| NIC order | hostfwd must hit `eth0` / `br-lan` | Single `eth0` → `br-lan` |
| LuCI | Not on minimal armsr download image by default | Install via `apk add luci-base` |
| Privileges | None | `--privileged` + `NET_ADMIN` (OpenWrt manages netdevs) |

## Official vs fwview wrapper

[openwrt/docker](https://github.com/openwrt/docker) documents the **`rootfs`** image as **experimental CI runtime** — run, test a package, exit:

```sh
docker run --rm -it ghcr.io/openwrt/rootfs:x86-64
# inside (24.10+ images may need ./setup.sh first if the tree is empty):
mkdir -p /var/lock
apk update && apk add tmate
```

That does **not** publish LuCI to your host or fix Docker bridge addressing. **`run-openwrt-x86-experiment.sh`** adds:

1. `docker run -d` with **`--privileged`**, **`NET_ADMIN`**, and **`-p 8080:80`**
2. **`/sbin/init`** so procd/network/firewall behave like a router
3. Bootstrap: LAN IP = Docker bridge (`172.17.0.x`), `apk add` LuCI + `uhttpd`, HTTP-only (no TLS cert hang in containers)

## What the bootstrap script does

1. Sets `network.lan` to the container’s Docker IP (e.g. `172.17.0.2/16`) and default route via `172.17.0.1`
2. `apk update` + `apk add luci-base luci-theme-bootstrap luci-mod-admin-full uhttpd`
3. Configures **HTTP-only** `uhttpd` (ucode LuCI handler; HTTPS listeners disabled)

## Stop / reset

```sh
docker rm -f owrt-x64-exp
```

## Compose (optional)

`docker compose up -d rootfs-x86` — same image and ports; run `./scripts/docker-rootfs-x86-bootstrap.sh` once after first start.

## Limitations (upstream)

The official `rootfs` image is **[experimental CI runtime](https://github.com/openwrt/docker)** — not a full router appliance. No persistent overlay unless you add a volume. Package versions are **SNAPSHOT**, not **24.10** release.

### Firewall log → Live View

Containers use the **host Linux kernel** (`uname -r` ≠ `/lib/modules/<openwrt-kernel>/`). **`nft`** counters and **`accept`/`drop`** work, but **`nft log`** often **does not appear in `logread`**, so **Firewall Live View** stays empty even when a ping log rule is installed and matching.

- Verify matching: `nft -a list chain inet fw4 input | grep counter` — packet count should rise when you ping the guest LAN IP.
- Validate the UI/parser anyway: `logger -t kernel -p kern.info "fwlive-test IN=br-lan SRC=172.17.0.1 DST=172.17.0.2 PROTO=ICMP ACCEPT"` then open Live View.
- For end-to-end **`nft log`** testing, use **QEMU armsr** or hardware — see [`fwlive-nft-logging.md`](fwlive-nft-logging.md).

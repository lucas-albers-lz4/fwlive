# QEMU lab

Headless OpenWrt guests for install and smoke testing without hardware.

## Images

Downloaded to `lab/images/`:

```sh
RELEASE=24.10.8 ./scripts/download-openwrt-x86-64.sh
RELEASE=23.05.5 ./scripts/download-openwrt-x86-64.sh
RELEASE=22.03.7 ./scripts/download-openwrt-x86-64.sh
RELEASE=21.02.7 ./scripts/download-openwrt-x86-64.sh
RELEASE=24.10.8 ./scripts/download-openwrt-armsr-armv8.sh
```

## Prepare image (required once per image)

Sets LAN **dhcp** for slirp, relaxes lab firewall, empty root password, dropbear auth, uhttpd/LuCI fixes. **22.03.x** fresh x86 images may lack `/etc/config/network` — the script seeds DHCP `lan` before first boot (see [22.03 notes](../supported-releases.md#2203x-eol)):

```sh
sudo OWRT_IMG=lab/images/openwrt-x86-64-24.10.8.img ./scripts/qemu-lab-prepare-image.sh
```

Always pass **`OWRT_IMG`** to the versioned file — the script default is the armsr image.

## Run

**x86 (KVM, fast):**

```sh
OWRT_RELEASE=24.10.8 ./scripts/run-openwrt-x86-qemu.sh
# stop: ./scripts/run-openwrt-x86-qemu.sh --stop
```

**armsr (TCG, slow):**

```sh
OWRT_RELEASE=24.10.8 ./scripts/run-openwrt-armsr-armv8-qemu.sh
```

Ports (default): LuCI **8080**, SSH **2222**.

Reset OVMF vars if GRUB hangs between matrix runs:

```sh
cp /usr/share/OVMF/OVMF_VARS_4M.fd lab/images/OVMF_VARS_4M.fd
```

## Install package on guest

```sh
./scripts/qemu-wait-guest.sh
OWRT_FWLIVE_VERSION=24.10.8 ./scripts/qemu-install-fwlive.sh
```

Uses `apk` or `opkg` based on package extension and guest userspace.

## Generate test traffic

```sh
./scripts/fwlive-nft-ping-log.sh add --ssh
ssh -p 2222 root@127.0.0.1 'ping -c 5 127.0.0.1'
./scripts/fwlive-ubus-read.sh --lines 20
```

Reset WAN logging state before toggle/uninstall tests (QEMU disk persists UCI):

```sh
./scripts/qemu-reset-wan-logging.sh
./scripts/qemu-logging-uninstall-smoke.sh
```

## Further reading

- [`../armvirt-armsr-testing.md`](../armvirt-armsr-testing.md)
- [`../openwrt-rootfs-x86-docker.md`](../openwrt-rootfs-x86-docker.md) — optional Docker experiment
- [`../../lab/README.md`](../../lab/README.md)

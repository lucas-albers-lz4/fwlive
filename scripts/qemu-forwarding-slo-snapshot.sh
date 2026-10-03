#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Read-only host/guest snapshot used by qemu-forwarding-slo-run.sh. Output is
# section-delimited so host and BusyBox guests can use the same collector.
set -u

scope=${1:-}
shift || true

section() {
	name=$1
	shift
	printf '\n###%s\n' "$name"
	"$@" 2>&1 || printf 'unavailable\n'
}

valid_device() {
	case "$1" in
		''|*[!A-Za-z0-9_.-]*) return 1 ;;
		*) [ "${#1}" -le 15 ] ;;
	esac
}

device_for_mac() {
	want=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	for address in /sys/class/net/*/address; do
		[ -r "$address" ] || continue
		got=$(cat "$address" 2>/dev/null | tr '[:upper:]' '[:lower:]') || continue
		if [ "$got" = "$want" ]; then
			printf '%s\n' "${address%/address}" | sed 's,.*/,,'
			return 0
		fi
	done
	return 1
}

snapshot_device() {
	dev=$1
	valid_device "$dev" || {
		printf 'device=%s invalid\n' "$dev"
		return
	}
	[ -d "/sys/class/net/$dev" ] || {
		printf 'device=%s missing\n' "$dev"
		return
	}
	printf '\n--- device=%s ---\n' "$dev"
	printf 'mac='
	cat "/sys/class/net/$dev/address" 2>/dev/null || true
	printf 'driver='
	readlink "/sys/class/net/$dev/device/driver" 2>/dev/null | sed 's,.*/,,' || true
	printf 'rx_queues='
	count=0
	for queue in /sys/class/net/"$dev"/queues/rx-*; do
		[ -d "$queue" ] && count=$((count + 1))
	done
	printf '%s\n' "$count"
	printf 'tx_queues='
	count=0
	for queue in /sys/class/net/"$dev"/queues/tx-*; do
		[ -d "$queue" ] && count=$((count + 1))
	done
	printf '%s\n' "$count"
	if command -v ip >/dev/null 2>&1; then
		ip -details -statistics link show dev "$dev" 2>&1 || true
	fi
	if command -v ethtool >/dev/null 2>&1; then
		ethtool -k "$dev" 2>&1 || true
		printf 'ethtool_channels:\n'
		channels=$(ethtool -l "$dev" 2>&1) && channel_status=0 || channel_status=$?
		if [ "$channel_status" -eq 0 ]; then
			printf '%s\n' "$channels"
		else
			printf 'unknown\n'
			[ -z "$channels" ] || printf 'ethtool_channels_error=%s\n' "$channels"
		fi
	else
		printf 'ethtool=unavailable\n'
		printf 'ethtool_channels=unknown\n'
	fi
}

case "$scope" in
--help|-h)
	echo 'usage: qemu-forwarding-slo-snapshot.sh host [LAN-TAP WAN-TAP CONSOLE-LOG] | guest [LAN-MAC WAN-MAC]'
	exit 0
	;;
host)
	lan_dev=${1:-fwlive-slo-ltap}
	wan_dev=${2:-fwlive-slo-wtap}
	console_log=${3:-}
	if ! valid_device "$lan_dev" || ! valid_device "$wan_dev"; then
		echo 'snapshot: invalid host device name' >&2
		exit 2
	fi
	section identity sh -c 'uname -a; cat /etc/os-release 2>/dev/null || true; printf "host_cpus="; getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || true'
	section cmdline cat /proc/cmdline
	section printk cat /proc/sys/kernel/printk
	section proc_stat cat /proc/stat
	section meminfo cat /proc/meminfo
	section interrupts cat /proc/interrupts
	section softirqs cat /proc/softirqs
	section softnet_stat cat /proc/net/softnet_stat
	printf '\n###affinity\n'
	if command -v taskset >/dev/null 2>&1; then
		for comm_file in /proc/[0-9]*/comm; do
			[ -r "$comm_file" ] || continue
			comm=$(cat "$comm_file" 2>/dev/null) || continue
			case "$comm" in
				qemu-system*)
					pid=${comm_file#/proc/}
					pid=${pid%/comm}
					printf 'qemu_pid=%s comm=%s\n' "$pid" "$comm"
					taskset -apc "$pid" 2>&1 || true
					;;
			esac
		done
	else
		printf 'taskset=unavailable\n'
	fi
	section dmesg_ring sh -c 'dmesg --raw 2>/dev/null | wc -cl || true'
	printf '\n###console_log\n'
	if [ -n "$console_log" ] && [ -r "$console_log" ]; then
		printf 'bytes='
		wc -c < "$console_log"
	else
		printf 'unavailable\n'
	fi
	printf '\n###devices\n'
	snapshot_device "$lan_dev"
	snapshot_device "$wan_dev"
	;;
guest)
	lan_mac=${1:-52:54:00:30:77:01}
	wan_mac=${2:-52:54:00:30:77:02}
	section identity sh -c 'uname -a; cat /etc/openwrt_release 2>/dev/null || true; cat /etc/os-release 2>/dev/null || true; printf "guest_cpus="; grep -c "^processor" /proc/cpuinfo 2>/dev/null || true'
	printf '\n###busybox_banner\n'
	if [ -r /bin/busybox ]; then
		busybox_banner=$(grep -aom1 'BusyBox v[0-9][^[:cntrl:]]*' /bin/busybox 2>/dev/null || true)
		[ -n "$busybox_banner" ] && printf '%s\n' "$busybox_banner" || printf 'unavailable\n'
	else
		printf 'unavailable\n'
	fi
	printf '\n###package_manager\n'
	if command -v apk >/dev/null 2>&1; then
		apk --version 2>&1 || true
		apk list --installed busybox 2>&1 || true
		apk list --installed luci-app-fwlive 2>&1 || true
	elif command -v opkg >/dev/null 2>&1; then
		opkg --version 2>&1 || true
		opkg status busybox 2>&1 || true
		opkg status luci-app-fwlive 2>&1 || true
	else
		printf 'unavailable\n'
	fi
	printf '\n###source_hashes\n'
	for source_file in /usr/libexec/rpcd/fwlive /usr/libexec/fwlive-adaptive-cap.sh \
		/www/luci-static/resources/view/status/fwlive.js /usr/share/rpcd/acl.d/luci-app-fwlive.json; do
		[ -f "$source_file" ] || continue
		if command -v sha256sum >/dev/null 2>&1; then sha256sum "$source_file"
		elif command -v md5sum >/dev/null 2>&1; then md5sum "$source_file"
		elif command -v cksum >/dev/null 2>&1; then cksum "$source_file"
		fi
	done
	section cmdline cat /proc/cmdline
	section printk cat /proc/sys/kernel/printk
	section proc_stat cat /proc/stat
	section meminfo cat /proc/meminfo
	section interrupts cat /proc/interrupts
	section softirqs cat /proc/softirqs
	section softnet_stat cat /proc/net/softnet_stat
	section cpu_online cat /sys/devices/system/cpu/online
	printf '\n###irq_affinity\n'
	for affinity_file in /proc/irq/*/smp_affinity_list; do
		[ -r "$affinity_file" ] || continue
		printf '%s=' "${affinity_file%/smp_affinity_list}"
		cat "$affinity_file"
	done
	section dmesg_ring sh -c 'dmesg --raw 2>/dev/null | wc -cl || true'
	printf '\n###devices\n'
	lan_dev=$(device_for_mac "$lan_mac" || true)
	wan_dev=$(device_for_mac "$wan_mac" || true)
	[ -n "$lan_dev" ] || lan_dev=missing-lan
	[ -n "$wan_dev" ] || wan_dev=missing-wan
	snapshot_device "$lan_dev"
	snapshot_device "$wan_dev"
	;;
*)
	echo 'usage: qemu-forwarding-slo-snapshot.sh host [LAN-TAP WAN-TAP CONSOLE-LOG] | guest [LAN-MAC WAN-MAC]' >&2
	exit 2
	;;
esac

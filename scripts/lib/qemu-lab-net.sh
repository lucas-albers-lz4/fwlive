# QEMU user-net lab (source from run-openwrt-*-qemu.sh).
#
# Recommended (verified on x86): default slirp + guest LAN DHCP + hostfwd:
#   -nic user,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22
#   (image: network.lan.proto=dhcp via qemu-lab-prepare-image.sh)
#   LuCI  http://localhost:8080/cgi-bin/luci/
#
# OWRT_LAB_NET_MODE=static + OWRT_LAB_SUBNET/IP for fixed guest addressing (armsr dual-NIC).

: "${OWRT_LAB_NET_MODE:=dhcp}"
: "${OWRT_LAB_SUBNET:=172.30.77.0/24}"
: "${OWRT_LAB_IP:=172.30.77.1}"
: "${OWRT_LAB_HOST:=172.30.77.15}"
: "${OWRT_LAB_WAN_SUBNET:=172.31.77.0/24}"
: "${OWRT_LAB_NETDEV_ID:=net0}"
: "${OWRT_HOSTFWD_BIND:=}"

qemu_lab_dhcp_start() {
	local guest_ip="$1"
	echo "${guest_ip%.*}.100"
}

qemu_lab_hostfwd_rule() {
	local proto="$1" host_port="$2" guest_port="$3"
	if [[ -n "$OWRT_HOSTFWD_BIND" ]]; then
		printf '%s:%s:%s-:%s' "$proto" "$OWRT_HOSTFWD_BIND" "$host_port" "$guest_port"
	else
		printf '%s::%s-:%s' "$proto" "$host_port" "$guest_port"
	fi
}

qemu_lab_hostfwd_pair() {
	local http_port="$1" ssh_port="$2"
	printf 'hostfwd=%s,hostfwd=%s' \
		"$(qemu_lab_hostfwd_rule tcp "$http_port" 80)" \
		"$(qemu_lab_hostfwd_rule tcp "$ssh_port" 22)"
}

# For qemu -nic user,... (x86 runner).
qemu_lab_nic_user() {
	local http_port="$1" ssh_port="$2"
	if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]]; then
		printf 'user,%s' "$(qemu_lab_hostfwd_pair "$http_port" "$ssh_port")"
	else
		printf 'user,id=%s,net=%s,dhcpstart=%s,host=%s,%s' \
			"$OWRT_LAB_NETDEV_ID" "$OWRT_LAB_SUBNET" \
			"$(qemu_lab_dhcp_start "$OWRT_LAB_IP")" "$OWRT_LAB_HOST" \
			"$(qemu_lab_hostfwd_pair "$http_port" "$ssh_port")"
	fi
}

# For qemu -netdev user,... -device virtio-net-pci (armsr runner).
qemu_lab_netdev_lan() {
	local http_port="$1" ssh_port="$2"
	if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]]; then
		printf 'user,id=%s,%s' "$OWRT_LAB_NETDEV_ID" "$(qemu_lab_hostfwd_pair "$http_port" "$ssh_port")"
	else
		printf 'user,id=%s,net=%s,dhcpstart=%s,host=%s,%s' \
			"$OWRT_LAB_NETDEV_ID" "$OWRT_LAB_SUBNET" \
			"$(qemu_lab_dhcp_start "$OWRT_LAB_IP")" "$OWRT_LAB_HOST" \
			"$(qemu_lab_hostfwd_pair "$http_port" "$ssh_port")"
	fi
}

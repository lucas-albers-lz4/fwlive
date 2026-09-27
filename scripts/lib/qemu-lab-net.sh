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

qemu_lab_validate_int() {
	local name="$1" val="$2" min="$3" max="$4"
	if [[ ! "$val" =~ ^[0-9]+$ ]]; then
		echo "invalid ${name}: '${val}' (want ${min}-${max})" >&2
		return 1
	fi
	if ((10#$val < min || 10#$val > max)); then
		echo "invalid ${name}: ${val} (want ${min}-${max})" >&2
		return 1
	fi
}

qemu_lab_validate_port() {
	qemu_lab_validate_int "$1" "$2" 1 65535
}

qemu_lab_port_owners_hint() {
	printf '%s' "stop lab/compose.yml (openwrt-x64), docker-compose.yml (owrt-x64-exp), or QEMU (./scripts/run-openwrt-x86-qemu.sh --stop / ./scripts/run-openwrt-armsr-armv8-qemu.sh --stop). See lab/README.md"
}

# Fail closed: invalid port, ss error, or a listener on the port.
qemu_lab_assert_host_port_free() {
	local port="$1" label="$2" out
	qemu_lab_validate_port "$label" "$port" || return 1
	if ! out="$(ss -tlnH "sport = :${port}" 2>&1)"; then
		echo "error: ss failed checking ${label} port ${port}: ${out}" >&2
		return 1
	fi
	if [[ -n "$out" ]]; then
		echo "error: host port ${port} (${label}) already in use — $(qemu_lab_port_owners_hint)" >&2
		return 1
	fi
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
	local model_arg=""
	case "${OWRT_QEMU_NIC_MODEL:-}" in
		'') ;;
		e1000|virtio-net-pci) model_arg=",model=${OWRT_QEMU_NIC_MODEL}" ;;
		*) echo "qemu-lab-net: unsupported QEMU management NIC model: ${OWRT_QEMU_NIC_MODEL}" >&2; return 1 ;;
	esac
	if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]]; then
		printf 'user,%s%s' "$(qemu_lab_hostfwd_pair "$http_port" "$ssh_port")" "$model_arg"
	else
		printf 'user,id=%s,net=%s,dhcpstart=%s,host=%s,%s%s' \
			"$OWRT_LAB_NETDEV_ID" "$OWRT_LAB_SUBNET" \
			"$(qemu_lab_dhcp_start "$OWRT_LAB_IP")" "$OWRT_LAB_HOST" \
			"$(qemu_lab_hostfwd_pair "$http_port" "$ssh_port")" "$model_arg"
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

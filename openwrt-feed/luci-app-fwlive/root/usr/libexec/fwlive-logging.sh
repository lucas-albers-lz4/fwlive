#!/bin/sh
# WAN zone logging helpers for ubus fwlive (logging_status / enable / disable).

NF_LOG_IPV4='/proc/sys/net/netfilter/nf_log/2'
NF_LOG_IPV6='/proc/sys/net/netfilter/nf_log/10'

find_wan_zone_section() {
	uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'$/\1/p" | head -1
}

wan_zone_log_value() {
	zone="$1"
	[ -n "$zone" ] || return 1
	uci -q get "firewall.${zone}.log" 2>/dev/null
}

wan_filter_log_enabled() {
	log_val="$1"
	[ -n "$log_val" ] || return 1
	case "$log_val" in
		*[!0-9]*) return 1 ;;
	esac
	[ $((log_val & 1)) -ne 0 ]
}

wan_filter_log_target_value() {
	current="$1"
	if wan_filter_log_enabled "$current"; then
		printf '%s' "$current"
		return 0
	fi
	case "$current" in
		''|*[!0-9]*)
			printf '1'
			;;
		*)
			printf '%d' $((current | 1))
			;;
	esac
}

read_nf_log_backend() {
	path="$1"
	[ -f "$path" ] || return 1
	val=$(cat "$path" 2>/dev/null)
	[ -n "$val" ] && [ "$val" != 'none' ]
}

check_nf_log_ipv4() {
	read_nf_log_backend "$NF_LOG_IPV4"
}

check_nf_log_ipv6() {
	read_nf_log_backend "$NF_LOG_IPV6"
}

logging_blockers_append() {
	blocker="$1"
	[ -n "$blocker" ] || return 0
	if [ -n "$LOGGING_BLOCKERS" ]; then
		LOGGING_BLOCKERS="${LOGGING_BLOCKERS},"
	fi
	LOGGING_BLOCKERS="${LOGGING_BLOCKERS}\"${blocker}\""
}

collect_logging_blockers() {
	zone="$1"
	LOGGING_BLOCKERS=''

	[ -n "$zone" ] || logging_blockers_append 'no_wan_zone'
	check_nf_log_ipv4 || logging_blockers_append 'nf_log_ipv4_missing'
	check_nf_log_ipv6 || logging_blockers_append 'nf_log_ipv6_missing'

	[ -n "$LOGGING_BLOCKERS" ] || return 0
	return 1
}

json_null_or_string() {
	val="$1"
	if [ -z "$val" ]; then
		printf 'null'
	else
		esc=$(printf '%s' "$val" | json_escape)
		printf '"%s"' "$esc"
	fi
}

build_logging_status_json() {
	zone=$(find_wan_zone_section)
	log_val=$(wan_zone_log_value "$zone")
	limit_val=$( [ -n "$zone" ] && uci -q get "firewall.${zone}.log_limit" 2>/dev/null )
	wan_log=false
	if wan_filter_log_enabled "$log_val"; then
		wan_log=true
	fi

	nf4=false
	check_nf_log_ipv4 && nf4=true
	nf6=false
	check_nf_log_ipv6 && nf6=true

	collect_logging_blockers "$zone"
	blockers="[${LOGGING_BLOCKERS:-}]"

	ready=false
	if [ -n "$zone" ] && [ "$wan_log" = true ] && [ "$nf4" = true ] && [ "$nf6" = true ]; then
		ready=true
	fi

	zone_json=$(json_null_or_string "$zone")
	limit_json=$(json_null_or_string "$limit_val")

	printf '{"wan_zone":%s,"wan_log":%s,"wan_log_limit":%s,"nf_log_ipv4":%s,"nf_log_ipv6":%s,"ready":%s,"blockers":%s}' \
		"$zone_json" "$wan_log" "$limit_json" "$nf4" "$nf6" "$ready" "$blockers"
}

reload_firewall() {
	if [ -x /etc/init.d/firewall ]; then
		/etc/init.d/firewall reload >/dev/null 2>&1
		return $?
	fi
	return 1
}

enable_wan_logging() {
	zone=$(find_wan_zone_section)
	if [ -z "$zone" ]; then
		printf '{"ok":false,"changed":false,"wan_zone":null,"error":"no_wan_zone"}'
		return 0
	fi

	if ! check_nf_log_ipv4 || ! check_nf_log_ipv6; then
		printf '{"ok":false,"changed":false,"wan_zone":"%s","error":"nf_log_missing"}' "$zone"
		return 0
	fi

	current=$(wan_zone_log_value "$zone")
	if wan_filter_log_enabled "$current"; then
		printf '{"ok":true,"changed":false,"wan_zone":"%s"}' "$zone"
		return 0
	fi

	target=$(wan_filter_log_target_value "$current")
	if ! uci set "firewall.${zone}.log=${target}"; then
		printf '{"ok":false,"changed":false,"wan_zone":"%s","error":"uci_set_failed"}' "$zone"
		return 0
	fi

	if ! uci commit firewall; then
		printf '{"ok":false,"changed":false,"wan_zone":"%s","error":"uci_commit_failed"}' "$zone"
		return 0
	fi

	if ! reload_firewall; then
		printf '{"ok":false,"changed":false,"wan_zone":"%s","error":"firewall_reload_failed"}' "$zone"
		return 0
	fi

	logger -t fwlive 'WAN zone logging enabled' 2>/dev/null || true
	printf '{"ok":true,"changed":true,"wan_zone":"%s"}' "$zone"
}

disable_wan_logging() {
	zone=$(find_wan_zone_section)
	if [ -z "$zone" ]; then
		printf '{"ok":false,"changed":false,"wan_zone":null,"error":"no_wan_zone"}'
		return 0
	fi

	current=$(wan_zone_log_value "$zone")
	if [ -z "$current" ] || ! wan_filter_log_enabled "$current"; then
		printf '{"ok":true,"changed":false,"wan_zone":"%s"}' "$zone"
		return 0
	fi

	if ! uci delete "firewall.${zone}.log"; then
		printf '{"ok":false,"changed":false,"wan_zone":"%s","error":"uci_delete_failed"}' "$zone"
		return 0
	fi

	if ! uci commit firewall; then
		printf '{"ok":false,"changed":false,"wan_zone":"%s","error":"uci_commit_failed"}' "$zone"
		return 0
	fi

	if ! reload_firewall; then
		printf '{"ok":false,"changed":false,"wan_zone":"%s","error":"firewall_reload_failed"}' "$zone"
		return 0
	fi

	logger -t fwlive 'WAN zone logging disabled' 2>/dev/null || true
	printf '{"ok":true,"changed":true,"wan_zone":"%s"}' "$zone"
}

run_logging_selftest() {
	if wan_filter_log_enabled ''; then
		echo 'wan_filter_log_enabled empty: expected false' >&2
		return 1
	fi
	if ! wan_filter_log_enabled '1'; then
		echo 'wan_filter_log_enabled 1: expected true' >&2
		return 1
	fi
	if ! wan_filter_log_enabled '3'; then
		echo 'wan_filter_log_enabled 3: expected true' >&2
		return 1
	fi
	if wan_filter_log_enabled '2'; then
		echo 'wan_filter_log_enabled 2: expected false' >&2
		return 1
	fi

	got=$(wan_filter_log_target_value '')
	if [ "$got" != '1' ]; then
		echo "wan_filter_log_target_value empty: expected 1 got $got" >&2
		return 1
	fi

	got=$(wan_filter_log_target_value '2')
	if [ "$got" != '3' ]; then
		echo "wan_filter_log_target_value 2: expected 3 got $got" >&2
		return 1
	fi

	got=$(wan_filter_log_target_value '1')
	if [ "$got" != '1' ]; then
		echo "wan_filter_log_target_value 1: expected 1 got $got" >&2
		return 1
	fi

	return 0
}

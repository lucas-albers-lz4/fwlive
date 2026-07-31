# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# GENERATED FILE — do not edit. Run: ./scripts/gen-all.sh
# source: core/fwlive-log.js CLASSIFY_SPEC
# Shared isFirewallEvent parity logic (shell). Sourced by fwlive-log-filter.sh and tests.

normalize_nf_msg() {
	printf '%s' "$1" | sed \
		-e 's/\([^[:space:]]\)\(IN=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(OUT=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(SRC=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(DST=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(PROTO=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(SPT=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(DPT=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(LEN=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(MAC=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(TYPE=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(CODE=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(TTL=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(TOS=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(PREC=\)/\1 \2/g' \
		-e 's/\([^[:space:]]\)\(DF=\)/\1 \2/g'
}

_detect_action() {
	msg="$1"
	action=$(printf '%s' "$msg" | grep -ioE '(^|[^A-Za-z0-9_])(ACCEPT|ALLOW|PASS|DROP|REJECT|DENY|BLOCK)([^A-Za-z0-9_]|$)' \
		| head -1 | sed 's/^[^A-Za-z]*//;s/[^A-Za-z]*$//')
	[ -n "$action" ] || action=UNKNOWN
	printf '%s' "$action"
}

_has_kv() {
	printf '%s' "$1" | grep -qE "(^|[^A-Za-z0-9_])$2="
}

_has_firewall_hint() {
	printf '%s' "$1" | grep -qiE '(^|[^A-Za-z0-9_])(fw4|nft|iptables|kernel|firewall)([^A-Za-z0-9_]|$)'
}

is_firewall_event_msg() {
	msg=$(normalize_nf_msg "$1")
	msg=$(printf '%s' "$msg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	[ -n "$msg" ] || return 1

	msg_lc=$(printf '%s' "$msg" | tr '[:upper:]' '[:lower:]')
	case "$msg_lc" in
		dnsmasq*|procd*|ubusd*|netifd*|odhcpd*|logd*|dropbear*|uhttpd*|hostapd*|wpad*) return 1 ;;
	esac

	action=$(_detect_action "$msg")

	if _has_kv "$msg" SRC && _has_kv "$msg" DST; then
		return 0
	fi
	if { _has_kv "$msg" IN || _has_kv "$msg" OUT; } && { _has_kv "$msg" SRC || _has_kv "$msg" DST || _has_kv "$msg" PROTO || _has_kv "$msg" SPT || _has_kv "$msg" DPT; }; then
		return 0
	fi
	if [ "$action" != "UNKNOWN" ] && { _has_kv "$msg" IN || _has_kv "$msg" OUT || _has_kv "$msg" PROTO || _has_kv "$msg" SRC || _has_kv "$msg" DST; }; then
		return 0
	fi

	if _has_firewall_hint "$msg" && [ "$action" != "UNKNOWN" ]; then
		return 0
	fi

	if _has_firewall_hint "$msg" && { _has_kv "$msg" IN || _has_kv "$msg" OUT || _has_kv "$msg" SRC || _has_kv "$msg" DST || _has_kv "$msg" PROTO; }; then
		return 0
	fi

	return 1
}

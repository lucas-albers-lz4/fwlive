# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Shared isFirewallEvent parity logic (shell). Sourced by fwlive-log-filter.sh and tests.
# Keep aligned with core/fwlive-log.js — see tests/fwlive-shell-filter.test.js

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

	case "$msg" in
		dnsmasq*|Dnsmasq*) return 1 ;;
		procd*|Procd*) return 1 ;;
		ubusd*|Ubusd*) return 1 ;;
		netifd*|Netifd*) return 1 ;;
		odhcpd*|Odhcpd*) return 1 ;;
		logd*|Logd*) return 1 ;;
		dropbear*|Dropbear*) return 1 ;;
		uhttpd*|Uhttpd*) return 1 ;;
		hostapd*|Hostapd*) return 1 ;;
		wpad*|Wpad*) return 1 ;;
	esac

	if _has_kv "$msg" SRC && _has_kv "$msg" DST; then
		return 0
	fi

	has_io=0
	_has_kv "$msg" IN && has_io=1
	_has_kv "$msg" OUT && has_io=1

	has_tuple=0
	_has_kv "$msg" SRC && has_tuple=1
	_has_kv "$msg" DST && has_tuple=1
	_has_kv "$msg" PROTO && has_tuple=1
	_has_kv "$msg" SPT && has_tuple=1
	_has_kv "$msg" DPT && has_tuple=1

	if [ "$has_io" -eq 1 ] && [ "$has_tuple" -eq 1 ]; then
		return 0
	fi

	action=$(_detect_action "$msg")
	if [ "$action" != "UNKNOWN" ]; then
		_has_kv "$msg" IN && return 0
		_has_kv "$msg" OUT && return 0
		_has_kv "$msg" PROTO && return 0
		_has_kv "$msg" SRC && return 0
		_has_kv "$msg" DST && return 0
	fi

	if _has_firewall_hint "$msg" && [ "$action" != "UNKNOWN" ]; then
		return 0
	fi

	if _has_firewall_hint "$msg"; then
		_has_kv "$msg" IN && return 0
		_has_kv "$msg" OUT && return 0
		_has_kv "$msg" SRC && return 0
		_has_kv "$msg" DST && return 0
		_has_kv "$msg" PROTO && return 0
	fi

	return 1
}

#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Filter log.read JSON to firewall-only entries (isFirewallEvent parity).
# Usage: ubus call log read '...' | /usr/libexec/fwlive-log-filter.sh

FILTER_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$FILTER_DIR/fwlive-is-firewall-event.sh"

input="$(cat)"
[ -n "$input" ] || input='{"log":[]}'

if ! command -v jsonfilter >/dev/null 2>&1; then
	printf '%s' '{"log":[]}'
	exit 0
fi

count=0
while jsonfilter -s "$input" -e "@.log[$count]" >/dev/null 2>&1; do
	count=$((count + 1))
done

[ "$count" -gt 0 ] || {
	printf '%s' '{"log":[]}'
	exit 0
}

printf '%s' '{"log":['
sep=''
idx=0
while [ "$idx" -lt "$count" ]; do
	entry=$(jsonfilter -s "$input" -e "@.log[$idx]")
	msg=$(printf '%s' "$entry" | jsonfilter -e '@.msg' 2>/dev/null)
	if is_firewall_event_msg "$msg"; then
		printf '%s%s' "$sep" "$entry"
		sep=','
	fi
	idx=$((idx + 1))
done
printf '%s' ']}'

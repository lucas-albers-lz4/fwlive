#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# WAN zone logging helpers for ubus fwlive (logging_status / enable / disable).

NF_LOG_IPV4='/proc/sys/net/netfilter/nf_log/2'
NF_LOG_IPV6='/proc/sys/net/netfilter/nf_log/10'

# Serialize the WAN logging read->compute->set->commit window across
# concurrent ubus write-ACL callers (#151): each toggle re-reads the current
# firewall.<zone>.log bit, computes a target, then uci set + uci commit. Two
# concurrent callers could otherwise interleave and last-commit-wins.
#
# BusyBox flock constraint: it has NO -w timeout. A stuck lock holder blocks
# any waiter until the holder exits or the device reboots. The critical
# section MUST stay SHORT (a few uci commands). Do NOT hold the lock across
# the /etc/init.d/firewall reload (can take seconds); the lock is released
# before reload, and reload-failure rollback is a best-effort UCI write
# outside the lock.
# Overridable for tests/containers (default is the production path).
WAN_LOG_LOCK_FILE="${FWLIVE_WAN_LOG_LOCK_FILE:-/var/lock/fwlive-logging.lock}"

# Acquire the exclusive logging lock on fd 9. Blocks until free; fails closed
# (return 1) only if the lock file cannot be opened or flock is unavailable.
acquire_wan_log_lock() {
	exec 9>"$WAN_LOG_LOCK_FILE" 2>/dev/null || return 1
	flock 9 2>/dev/null || {
		exec 9>&-
		return 1
	}
}

# Release the logging lock (explicit unlock, then close fd 9).
release_wan_log_lock() {
	flock -u 9 2>/dev/null || true
	exec 9>&-
}

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

# Clear filter-log bit 0 only. Prints remaining value, or empty when the option
# should be deleted (no bits left / non-numeric / already empty).
wan_filter_log_clear_value() {
	current="$1"
	case "$current" in
		''|*[!0-9]*)
			printf ''
			return 0
			;;
	esac
	cleared=$((current & ~1))
	if [ "$cleared" -eq 0 ]; then
		printf ''
	else
		printf '%d' "$cleared"
	fi
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
	esc=$(printf '%s' "$blocker" | json_escape)
	if [ -n "$LOGGING_BLOCKERS" ]; then
		LOGGING_BLOCKERS="${LOGGING_BLOCKERS},"
	fi
	LOGGING_BLOCKERS="${LOGGING_BLOCKERS}\"${esc}\""
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

# Best-effort UCI rollback when firewall reload fails after commit.
restore_wan_zone_log() {
	zone="$1"
	previous="$2"
	[ -n "$zone" ] || return 1
	if [ -z "$previous" ]; then
		uci -q delete "firewall.${zone}.log" 2>/dev/null || true
	else
		uci -q set "firewall.${zone}.log=${previous}" 2>/dev/null || true
	fi
	uci commit firewall 2>/dev/null || true
}

# Commit the staged log bit. Caller MUST hold the logging lock; this closes
# the read->compute->set->commit window so a concurrent toggle cannot commit
# between our read and our write (no lost update / no stale overwrite).
# Prints the failure JSON and returns 1 on commit failure.
commit_wan_log_change() {
	zone="$1"
	zone_json="$2"
	if uci commit firewall; then
		return 0
	fi
	printf '{"ok":false,"changed":false,"wan_zone":%s,"error":"uci_commit_failed"}' "$zone_json"
	return 1
}

# Firewall reload + best-effort UCI rollback on reload failure. The reload
# itself runs WITHOUT the logging lock (it can take seconds and a held lock
# would block a concurrent toggle until the holder exits — BusyBox flock has
# no -w timeout).
#
# The ROLLBACK re-acquires the lock (luna fold 2026-08-10): read->compare->
# restore is only atomic when no other writer can commit between the read and
# the restore. All writers hold the same flock, so re-acquiring it makes the
# decision-and-restore a serialized unit. The lock is held only for the few
# uci commands of the restore (short critical section), never across the
# reload. If the lock cannot be re-acquired, skip the rollback (report the
# reload failure; the next toggle self-corrects).
reload_and_report_wan_log() {
	zone="$1"
	previous="$2"
	committed="$3"
	fail_msg="$4"
	success_msg="$5"
	zone_json="$6"

	if ! reload_firewall; then
		# Re-acquire the logging lock so the rollback decision is atomic
		# against concurrent toggles (no check-then-restore race).
		if acquire_wan_log_lock; then
			now="$(wan_zone_log_value "$zone")"
			if [ "$now" = "$committed" ]; then
				# Current value is still what THIS caller committed — restore
				# the pre-commit value. (If a concurrent toggle committed the
				# same value, the toggle is idempotent: the state intent is
				# identical, so restoring previous is the correct rollback.)
				restore_wan_zone_log "$zone" "$previous"
				logger -t fwlive "$fail_msg" 2>/dev/null || true
			else
				# A concurrent toggle changed the value after our commit; do
				# not clobber it. Log the divergence and leave the newer value.
				logger -t fwlive "Firewall reload failed; WAN log changed concurrently — rollback skipped" 2>/dev/null || true
			fi
			release_wan_log_lock
		else
			# Cannot re-acquire the lock: skip the rollback, report the
			# reload failure. The next toggle self-corrects the state.
			logger -t fwlive "Firewall reload failed; rollback lock unavailable — skipped" 2>/dev/null || true
		fi
		printf '{"ok":false,"changed":false,"wan_zone":%s,"error":"firewall_reload_failed"}' "$zone_json"
		return 0
	fi
	logger -t fwlive "$success_msg" 2>/dev/null || true
	printf '{"ok":true,"changed":true,"wan_zone":%s}' "$zone_json"
	return 0
}

enable_wan_logging() {
	zone=$(find_wan_zone_section)
	if [ -z "$zone" ]; then
		printf '{"ok":false,"changed":false,"wan_zone":null,"error":"no_wan_zone"}'
		return 0
	fi

	zone_json=$(json_null_or_string "$zone")

	if ! check_nf_log_ipv4 || ! check_nf_log_ipv6; then
		printf '{"ok":false,"changed":false,"wan_zone":%s,"error":"nf_log_missing"}' "$zone_json"
		return 0
	fi

	# Locked critical section: read->compute->set->commit for firewall.<zone>.log.
	# The log bit is re-read AFTER acquiring the lock so the target is computed
	# from the latest committed value; a concurrent toggle cannot interleave.
	if ! acquire_wan_log_lock; then
		printf '{"ok":false,"changed":false,"wan_zone":%s,"error":"lock_failed"}' "$zone_json"
		return 0
	fi

	current=$(wan_zone_log_value "$zone")
	if wan_filter_log_enabled "$current"; then
		release_wan_log_lock
		printf '{"ok":true,"changed":false,"wan_zone":%s}' "$zone_json"
		return 0
	fi

	target=$(wan_filter_log_target_value "$current")
	if ! uci set "firewall.${zone}.log=${target}"; then
		release_wan_log_lock
		printf '{"ok":false,"changed":false,"wan_zone":%s,"error":"uci_set_failed"}' "$zone_json"
		return 0
	fi
	if ! commit_wan_log_change "$zone" "$zone_json"; then
		release_wan_log_lock
		return 0
	fi
	release_wan_log_lock

	reload_and_report_wan_log "$zone" "$current" "$target" \
		'Firewall reload failed after enable; reverted UCI WAN log' \
		'WAN zone logging enabled' \
		"$zone_json"
	return 0
}

disable_wan_logging() {
	zone=$(find_wan_zone_section)
	if [ -z "$zone" ]; then
		printf '{"ok":false,"changed":false,"wan_zone":null,"error":"no_wan_zone"}'
		return 0
	fi

	zone_json=$(json_null_or_string "$zone")

	# Locked critical section: read->compute->set->commit for firewall.<zone>.log.
	# The log bit is re-read AFTER acquiring the lock so the target is computed
	# from the latest committed value; a concurrent toggle cannot interleave.
	if ! acquire_wan_log_lock; then
		printf '{"ok":false,"changed":false,"wan_zone":%s,"error":"lock_failed"}' "$zone_json"
		return 0
	fi

	current=$(wan_zone_log_value "$zone")
	if [ -z "$current" ] || ! wan_filter_log_enabled "$current"; then
		release_wan_log_lock
		printf '{"ok":true,"changed":false,"wan_zone":%s}' "$zone_json"
		return 0
	fi

	target=$(wan_filter_log_clear_value "$current")
	if [ -z "$target" ]; then
		if ! uci delete "firewall.${zone}.log"; then
			release_wan_log_lock
			printf '{"ok":false,"changed":false,"wan_zone":%s,"error":"uci_delete_failed"}' "$zone_json"
			return 0
		fi
	else
		if ! uci set "firewall.${zone}.log=${target}"; then
			release_wan_log_lock
			printf '{"ok":false,"changed":false,"wan_zone":%s,"error":"uci_set_failed"}' "$zone_json"
			return 0
		fi
	fi
	if ! commit_wan_log_change "$zone" "$zone_json"; then
		release_wan_log_lock
		return 0
	fi
	release_wan_log_lock

	reload_and_report_wan_log "$zone" "$current" "$target" \
		'Firewall reload failed after disable; reverted UCI WAN log' \
		'WAN zone logging disabled' \
		"$zone_json"
	return 0
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

	# Disable clears bit 0 only: log=3 -> 2; log=1 -> delete (empty).
	got=$(wan_filter_log_clear_value '3')
	if [ "$got" != '2' ]; then
		echo "wan_filter_log_clear_value 3: expected 2 got $got" >&2
		return 1
	fi

	got=$(wan_filter_log_clear_value '1')
	if [ -n "$got" ]; then
		echo "wan_filter_log_clear_value 1: expected empty got $got" >&2
		return 1
	fi

	got=$(wan_filter_log_clear_value '2')
	if [ "$got" != '2' ]; then
		echo "wan_filter_log_clear_value 2: expected 2 got $got" >&2
		return 1
	fi

	# Enable/disable parity around multi-bit values.
	got=$(wan_filter_log_target_value '2')
	if [ "$got" != '3' ]; then
		echo "enable from 2: expected 3 got $got" >&2
		return 1
	fi
	got=$(wan_filter_log_clear_value '3')
	if [ "$got" != '2' ]; then
		echo "disable from 3: expected 2 got $got" >&2
		return 1
	fi

	return 0
}

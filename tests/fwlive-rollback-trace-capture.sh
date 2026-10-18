#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Test-only observation fixture for the #1121 bounded rollback replay pilot.
# Sources the unchanged production helper and records facts, not TLA action names.
set -eu

logging_sh="$1"
scenario="$2"
root="$3"
primary_intent="${4:-enable}"
initial_value="${5:-unset}"
schedule="${6:-}"

case "$scenario" in
	success|aba|noop|failed|failedstage|refusal|reacquire|generation|stage|poststage|commit|scheduled) ;;
	*) echo "unknown rollback capture scenario: $scenario" >&2; exit 2 ;;
esac
case "$primary_intent" in
	enable|disable) ;;
	*) echo "invalid primary rollback intent: $primary_intent" >&2; exit 2 ;;
esac
case "$initial_value" in
	unset|0|1) ;;
	*) echo "invalid initial rollback value: $initial_value" >&2; exit 2 ;;
esac
case "$schedule" in
	,*|*,|*,,*) echo 'invalid rollback schedule: empty token' >&2; exit 2 ;;
esac
schedule_count=0
schedule_remaining="$schedule"
while [ -n "$schedule_remaining" ]; do
	case "$schedule_remaining" in
		*,*) directive="${schedule_remaining%%,*}"; schedule_remaining="${schedule_remaining#*,}" ;;
		*) directive="$schedule_remaining"; schedule_remaining='' ;;
	esac
	case "$directive" in
		enable|disable|fail-enable|fail-disable) ;;
		*) echo "invalid rollback schedule token: $directive" >&2; exit 2 ;;
	esac
	schedule_count=$((schedule_count + 1))
	[ "$schedule_count" -le 2 ] || { echo 'rollback schedule exceeds two attempts' >&2; exit 2; }
done
trace="$root/observations.tsv"
mkdir -p "$root" "$root/run" "$root/bin"
chmod 0700 "$root" "$root/run" "$root/bin"
: > "$trace"
rm -f "$root/current" "$root/run/generation" "$root/lock" "$root/baseline" "$root/staged" "$root/foreign-stage"
if [ "$initial_value" != unset ]; then
	printf '%s' "$initial_value" >"$root/current"
fi
printf '0\n' > "$root/commit-count"

real_flock=$(command -v flock)
real_mktemp=$(command -v mktemp)
cat > "$root/bin/flock" <<'EOF'
#!/bin/sh
rc=0
case "$*" in
	'-n 9')
		count_file="$PILOT_ROOT/flock-attempts-$PILOT_CALLER_PID"
		count=0
		[ -f "$count_file" ] && count=$(cat "$count_file")
		count=$((count + 1))
		printf '%s\n' "$count" >"$count_file"
		if [ "$PILOT_SCENARIO" = reacquire ] \
			&& [ "$PILOT_ROLE" = primary ] && [ "$count" -eq 2 ]; then
			rc=2
		else
			"$PILOT_REAL_FLOCK" "$@"
			rc=$?
		fi
		;;
	*)
		"$PILOT_REAL_FLOCK" "$@"
		rc=$?
		;;
esac
printf 'FLOCK|%s|%s|%s|%s|%s|%s|%s|%s\n' "$PILOT_SCENARIO" "$PILOT_ROLE" \
	"$PILOT_CALLER_PID" "$PILOT_INTENT" "$*" "$rc" \
	"$(cat "$PILOT_CURRENT" 2>/dev/null || printf unset)" \
	"$(cat "$FWLIVE_WAN_LOG_GENERATION_FILE" 2>/dev/null || printf 0)" >> "$PILOT_TRACE"
exit "$rc"
EOF
chmod +x "$root/bin/flock"
cat > "$root/bin/mktemp" <<'EOF'
#!/bin/sh
# Baseline snapshots also use mktemp. Observe only generation allocations.
case "${1:-}" in
	"${FWLIVE_WAN_LOG_GENERATION_FILE}."*) ;;
	*) exec "$PILOT_REAL_MKTEMP" "$@" ;;
esac
count_file="$PILOT_ROOT/generation-temp-attempts-$PILOT_CALLER_PID"
count=0
[ -f "$count_file" ] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [ "$PILOT_SCENARIO" = generation ] \
	&& [ "$PILOT_ROLE" = primary ] && [ "$count" -eq 2 ]; then
	rc=1
else
	"$PILOT_REAL_MKTEMP" "$@"
	rc=$?
fi
printf 'GENERATION_TEMP|%s|%s|%s|%s|%s|%s|%s\n' "$PILOT_SCENARIO" \
	"$PILOT_ROLE" "$PILOT_CALLER_PID" "$PILOT_INTENT" "$rc" \
	"$(cat "$PILOT_CURRENT" 2>/dev/null || printf unset)" \
	"$(cat "$FWLIVE_WAN_LOG_GENERATION_FILE" 2>/dev/null || printf 0)" >>"$PILOT_TRACE"
exit "$rc"
EOF
chmod +x "$root/bin/mktemp"
export PILOT_REAL_FLOCK="$real_flock"
export PILOT_REAL_MKTEMP="$real_mktemp"
export PILOT_SCENARIO="$scenario"
export PILOT_PRIMARY_INTENT="$primary_intent"
export PILOT_INITIAL_VALUE="$initial_value"
export PILOT_SCHEDULE="$schedule"
export PILOT_TRACE="$trace"
export PILOT_ROOT="$root"
export PATH="$root/bin:$PATH"
export FWLIVE_WAN_LOG_LOCK_FILE="$root/lock"
export FWLIVE_WAN_LOG_GENERATION_FILE="$root/run/generation"
export FWLIVE_WAN_LOG_BASELINE_FILE="$root/baseline"

cat > "$root/runner.sh" <<'EOF'
#!/bin/sh
set -eu
PILOT_ROLE="$1"
intent="$2"
PILOT_FAIL_COMMIT="${3:-0}"
PILOT_FAIL_STAGE="${4:-0}"
PILOT_CALLER_PID=$$
PILOT_INTENT="$intent"
export PILOT_ROLE PILOT_CALLER_PID PILOT_INTENT PILOT_FAIL_COMMIT PILOT_FAIL_STAGE
. "$PILOT_LOGGING_SH"
PILOT_CURRENT="$PILOT_ROOT/current"
PILOT_STAGE="$PILOT_ROOT/staged"
PILOT_COMMIT_COUNT="$PILOT_ROOT/commit-count"
PILOT_FOREIGN_STAGE="$PILOT_ROOT/foreign-stage"
export PILOT_CURRENT PILOT_STAGE PILOT_COMMIT_COUNT PILOT_FOREIGN_STAGE

value() {
	if [ -f "$PILOT_CURRENT" ]; then cat "$PILOT_CURRENT"; else printf unset; fi
}
generation() {
	if [ -f "$FWLIVE_WAN_LOG_GENERATION_FILE" ]; then cat "$FWLIVE_WAN_LOG_GENERATION_FILE"; else printf 0; fi
}
observe() {
	printf 'SNAP|%s|%s|%s|%s|%s|%s|%s\n' "$PILOT_SCENARIO" "$PILOT_ROLE" \
		"$PILOT_CALLER_PID" "$1" "$intent" "$(value)" "$(generation)" >> "$PILOT_TRACE"
}

uci() {
	before_value=$(value)
	before_generation=$(generation)
	operation="$*"
	changes_observed=''
	rc=0
	case "$*" in
		'-q show firewall')
			printf "firewall.@zone[0]=zone\nfirewall.@zone[0].name='wan'\nfirewall.@zone[0].network='wan'\n"
			;;
		'-q get firewall.@zone[0]') printf 'zone\n' ;;
		'-q get firewall.@zone[0].name') printf 'wan\n' ;;
		'-q get firewall.@zone[0].network') printf 'wan\n' ;;
		'-q get firewall.@zone[0].log')
			[ -f "$PILOT_CURRENT" ] || rc=1
			[ "$rc" -ne 0 ] || cat "$PILOT_CURRENT"
			;;
		'-q changes firewall')
			if [ -f "$PILOT_FOREIGN_STAGE" ]; then
				changes_observed=$(cat "$PILOT_FOREIGN_STAGE")
				printf '%s\n' "$changes_observed"
			fi
			if [ -f "$PILOT_STAGE" ]; then
				staged=$(cat "$PILOT_STAGE")
				if [ "$staged" = __unset__ ]; then
					change_line='-firewall.@zone[0].log'
				else
					change_line="firewall.@zone[0].log='$staged'"
				fi
				printf '%s\n' "$change_line"
				if [ -n "$changes_observed" ]; then changes_observed="$changes_observed; $change_line"; else changes_observed="$change_line"; fi
			fi
			printf 'CHANGES|%s|%s|%s|%s|%s|%s|%s|%s\n' "$PILOT_SCENARIO" \
				"$PILOT_ROLE" "$PILOT_CALLER_PID" "$PILOT_INTENT" "$rc" \
				"$(value)" "$(generation)" "${changes_observed:-empty}" >> "$PILOT_TRACE"
			;;
		'set firewall.@zone[0].log='*)
			if { [ "$PILOT_SCENARIO" = stage ] && [ "$PILOT_ROLE" = primary ] \
				&& [ "$(cat "$PILOT_COMMIT_COUNT")" -ge 1 ]; } \
				|| { [ "$PILOT_ROLE" = secondary ] && [ "$PILOT_FAIL_STAGE" = 1 ]; }; then
				rc=1
			else
				printf '%s' "${2#*=}" >"$PILOT_STAGE"
				if [ "$PILOT_SCENARIO" = poststage ] && [ "$PILOT_ROLE" = primary ] \
					&& [ "$(cat "$PILOT_COMMIT_COUNT")" -ge 1 ]; then
					printf '%s\n' "firewall.@zone[9].log_limit='77'" >"$PILOT_FOREIGN_STAGE"
				fi
			fi
			;;
		'-q set firewall.@zone[0].log='*)
			if { [ "$PILOT_SCENARIO" = stage ] && [ "$PILOT_ROLE" = primary ] \
				&& [ "$(cat "$PILOT_COMMIT_COUNT")" -ge 1 ]; } \
				|| { [ "$PILOT_ROLE" = secondary ] && [ "$PILOT_FAIL_STAGE" = 1 ]; }; then
				rc=1
			else
				printf '%s' "${3#*=}" >"$PILOT_STAGE"
				if [ "$PILOT_SCENARIO" = poststage ] && [ "$PILOT_ROLE" = primary ] \
					&& [ "$(cat "$PILOT_COMMIT_COUNT")" -ge 1 ]; then
					printf '%s\n' "firewall.@zone[9].log_limit='77'" >"$PILOT_FOREIGN_STAGE"
				fi
			fi
			;;
		'delete firewall.@zone[0].log'|'-q delete firewall.@zone[0].log')
			if { [ "$PILOT_SCENARIO" = stage ] && [ "$PILOT_ROLE" = primary ] \
				&& [ "$(cat "$PILOT_COMMIT_COUNT")" -ge 1 ]; } \
				|| { [ "$PILOT_ROLE" = secondary ] && [ "$PILOT_FAIL_STAGE" = 1 ]; }; then
				rc=1
			else
				printf '%s' __unset__ >"$PILOT_STAGE"
				if [ "$PILOT_SCENARIO" = poststage ] && [ "$PILOT_ROLE" = primary ] \
					&& [ "$(cat "$PILOT_COMMIT_COUNT")" -ge 1 ]; then
					printf '%s\n' "firewall.@zone[9].log_limit='77'" >"$PILOT_FOREIGN_STAGE"
				fi
			fi
			;;
		'commit firewall'|'-q commit firewall')
			count=$(cat "$PILOT_COMMIT_COUNT")
			previous_count=$count
			count=$((count + 1))
			printf '%s\n' "$count" > "$PILOT_COMMIT_COUNT"
			if { [ "$PILOT_SCENARIO" = failed ] && [ "$PILOT_ROLE" = secondary ]; } \
				|| { [ "$PILOT_SCENARIO" = commit ] && [ "$PILOT_ROLE" = primary ] && [ "$previous_count" -ge 1 ]; } \
				|| { [ "$PILOT_ROLE" = secondary ] && [ "$PILOT_FAIL_COMMIT" = 1 ]; }; then
				rc=1
			elif [ -f "$PILOT_STAGE" ]; then
				staged=$(cat "$PILOT_STAGE")
				if [ "$staged" = __unset__ ]; then rm -f "$PILOT_CURRENT"; else printf '%s' "$staged" > "$PILOT_CURRENT"; fi
				rm -f "$PILOT_STAGE"
			fi
			;;
		'-q revert firewall.'*) rm -f "$PILOT_STAGE" ;;
		*) rc=0 ;;
	esac
	after_value=$(value)
	after_generation=$(generation)
	case "$operation" in
		'set '*|'delete '*|'-q set '*|'-q delete '*|'commit firewall'|'-q commit firewall'|'-q revert firewall.'*)
			printf 'UCI|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$PILOT_SCENARIO" \
				"$PILOT_ROLE" "$PILOT_CALLER_PID" "$PILOT_INTENT" "$operation" "$rc" \
				"$before_value" "$after_value" "$before_generation" "$after_generation" >> "$PILOT_TRACE"
			;;
	esac
	return "$rc"
}
json_escape() { cat; }
check_nf_log_ipv4() { return 0; }
check_nf_log_ipv6() { return 0; }
logger() {
	printf 'LOG|%s|%s|%s|%s|%s|%s|%s\n' "$PILOT_SCENARIO" "$PILOT_ROLE" \
		"$PILOT_CALLER_PID" "$PILOT_INTENT" "$(value)" "$(generation)" "$*" >> "$PILOT_TRACE"
}

reload_firewall() {
	before_value=$(value)
	before_generation=$(generation)
	if [ "$PILOT_ROLE" = primary ]; then
		case "$PILOT_SCENARIO" in
			aba)
				if [ "$PILOT_PRIMARY_INTENT" = enable ]; then opposite=disable; else opposite=enable; fi
				sh "$0" secondary "$opposite"
				sh "$0" secondary "$PILOT_PRIMARY_INTENT"
				;;
			noop)
				sh "$0" secondary "$PILOT_PRIMARY_INTENT"
				;;
			failed)
				if [ "$PILOT_PRIMARY_INTENT" = enable ]; then opposite=disable; else opposite=enable; fi
				sh "$0" secondary "$opposite" 1
				;;
			failedstage)
				if [ "$PILOT_PRIMARY_INTENT" = enable ]; then opposite=disable; else opposite=enable; fi
				sh "$0" secondary "$opposite" 0 1
				;;
			refusal)
				printf "firewall.@zone[0].log_limit='77'\\n" > "$PILOT_FOREIGN_STAGE"
				;;
		esac
		schedule_remaining="$PILOT_SCHEDULE"
		while [ -n "$schedule_remaining" ]; do
			case "$schedule_remaining" in
				*,*) directive="${schedule_remaining%%,*}"; schedule_remaining="${schedule_remaining#*,}" ;;
				*) directive="$schedule_remaining"; schedule_remaining='' ;;
			esac
			case "$directive" in
				enable) secondary_intent=enable; fail_commit=0 ;;
				disable) secondary_intent=disable; fail_commit=0 ;;
				fail-enable) secondary_intent=enable; fail_commit=1 ;;
				fail-disable) secondary_intent=disable; fail_commit=1 ;;
				*) exit 2 ;;
			esac
			sh "$0" secondary "$secondary_intent" "$fail_commit"
		done
		rc=1
	else
		rc=0
	fi
	printf 'RELOAD|%s|%s|%s|%s|%s|%s|%s\n' "$PILOT_SCENARIO" "$PILOT_ROLE" \
		"$PILOT_CALLER_PID" "$PILOT_INTENT" "$rc" "$(value)" "$(generation)" >> "$PILOT_TRACE"
	return "$rc"
}

observe begin
call_rc=0
case "$intent" in
	enable) enable_wan_logging > "$PILOT_ROOT/$PILOT_ROLE-$intent.json" || call_rc=$? ;;
	disable) disable_wan_logging > "$PILOT_ROOT/$PILOT_ROLE-$intent.json" || call_rc=$? ;;
	*) exit 2 ;;
esac
observe "return:$call_rc"
printf 'JSON|%s|%s|%s|%s|%s\n' "$PILOT_SCENARIO" "$PILOT_ROLE" "$PILOT_CALLER_PID" "$intent" \
	"$(cat "$PILOT_ROOT/$PILOT_ROLE-$intent.json")" >> "$PILOT_TRACE"
EOF
chmod +x "$root/runner.sh"
export PILOT_LOGGING_SH="$logging_sh"
printf 'INITIAL|%s|%s|%s|0\n' "$scenario" "$$" "$initial_value" >> "$trace"
sh "$root/runner.sh" primary "$primary_intent"
cat "$trace"

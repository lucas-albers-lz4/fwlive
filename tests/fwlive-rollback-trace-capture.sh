#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Test-only observation fixture for the #1121 bounded rollback replay pilot.
# Sources the unchanged production helper and records facts, not TLA action names.
set -eu

logging_sh="$1"
scenario="$2"
root="$3"
trace="$root/observations.tsv"
mkdir -p "$root" "$root/run" "$root/bin"
chmod 0700 "$root" "$root/run" "$root/bin"
: > "$trace"
: > "$root/current"
rm -f "$root/current" "$root/run/generation" "$root/lock" "$root/baseline" "$root/staged" "$root/foreign-stage"
: > "$root/commit-count"

real_flock=$(command -v flock)
cat > "$root/bin/flock" <<'EOF'
#!/bin/sh
"$PILOT_REAL_FLOCK" "$@"
rc=$?
printf 'FLOCK|%s|%s|%s|%s|%s|%s|%s|%s\n' "$PILOT_SCENARIO" "$PILOT_ROLE" \
	"$PILOT_CALLER_PID" "$PILOT_INTENT" "$*" "$rc" \
	"$(cat "$PILOT_CURRENT" 2>/dev/null || printf unset)" \
	"$(cat "$FWLIVE_WAN_LOG_GENERATION_FILE" 2>/dev/null || printf 0)" >> "$PILOT_TRACE"
exit "$rc"
EOF
chmod +x "$root/bin/flock"
export PILOT_REAL_FLOCK="$real_flock"
export PILOT_SCENARIO="$scenario"
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
PILOT_CALLER_PID=$$
PILOT_INTENT="$intent"
export PILOT_ROLE PILOT_CALLER_PID PILOT_INTENT
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
		'set firewall.@zone[0].log='*) printf '%s' "${2#*=}" > "$PILOT_STAGE" ;;
		'-q set firewall.@zone[0].log='*) printf '%s' "${3#*=}" > "$PILOT_STAGE" ;;
		'delete firewall.@zone[0].log'|'-q delete firewall.@zone[0].log') printf '%s' __unset__ > "$PILOT_STAGE" ;;
		'commit firewall'|'-q commit firewall')
			count=$(cat "$PILOT_COMMIT_COUNT")
			count=$((count + 1))
			printf '%s\n' "$count" > "$PILOT_COMMIT_COUNT"
			if [ "$PILOT_SCENARIO" = failed ] && [ "$PILOT_ROLE" = secondary ]; then
				rc=1
			elif [ -f "$PILOT_STAGE" ]; then
				staged=$(cat "$PILOT_STAGE")
				if [ "$staged" = __unset__ ]; then rm -f "$PILOT_CURRENT"; else printf '%s' "$staged" > "$PILOT_CURRENT"; fi
				rm -f "$PILOT_STAGE"
			fi
			;;
		'-q revert firewall') rm -f "$PILOT_STAGE" ;;
		*) rc=0 ;;
	esac
	after_value=$(value)
	after_generation=$(generation)
	case "$operation" in
		'set '*|'delete '*|'-q set '*|'-q delete '*|'commit firewall'|'-q commit firewall'|'-q revert firewall')
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
				sh "$0" secondary disable
				sh "$0" secondary enable
				;;
			noop)
				sh "$0" secondary enable
				;;
			failed)
				sh "$0" secondary disable
				;;
			refusal)
				printf "firewall.@zone[0].log_limit='77'\\n" > "$PILOT_FOREIGN_STAGE"
				;;
		esac
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
printf 'INITIAL|%s|%s|unset|0\n' "$scenario" "$$" >> "$trace"
sh "$root/runner.sh" primary enable
cat "$trace"

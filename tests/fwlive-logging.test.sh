#!/usr/bin/env bash
# Unit tests for fwlive-logging.sh helpers (no UCI/firewall required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGGING_SH="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh"
RPCD="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive"

die() { echo "fwlive-logging test FAIL: $*" >&2; exit 1; }
ok() { echo "fwlive-logging test OK: $*"; }

json_escape() {
	awk 'BEGIN { RS = ""; ORS = "" }
	{
		for (i = 1; i <= length($0); i++) {
			c = substr($0, i, 1)
			if (c == "\\") printf "\\\\"
			else if (c == "\"") printf "\\\""
			else if (c == "\t") printf "\\t"
			else if (c == "\r") printf "\\r"
			else if (c == "\n") printf "\\n"
			else printf "%s", c
		}
	}'
}

. "$LOGGING_SH"

run_logging_selftest || die "run_logging_selftest"
ok "filter log bit logic"

out=$(build_logging_status_json)
case "$out" in
	*'"wan_log":'*) ;;
	*) die "logging_status JSON missing wan_log: $out" ;;
esac
case "$out" in
	*'"blockers":'*) ;;
	*) die "logging_status JSON missing blockers: $out" ;;
esac
ok "build_logging_status_json shape"

# restore_wan_zone_log: empty previous => delete; non-empty => set + commit
UCI_LOG=()
uci() {
	UCI_LOG+=("$*")
	return 0
}
UCI_LOG=()
restore_wan_zone_log '@zone[0]' ''
joined="${UCI_LOG[*]}"
case "$joined" in
	*'-q delete firewall.@zone[0].log'*'commit firewall'*) ;;
	*) die "restore empty previous expected delete+commit, got: $joined" ;;
esac
UCI_LOG=()
restore_wan_zone_log '@zone[1]' '3'
joined="${UCI_LOG[*]}"
case "$joined" in
	*'-q set firewall.@zone[1].log=3'*'commit firewall'*) ;;
	*) die "restore value expected set+commit, got: $joined" ;;
esac
unset -f uci
ok "restore_wan_zone_log stubs"

# find_wan_zone_section: named zone + anonymous zone (issue #168)
uci() {
	case "$*" in
		'-q show firewall')
			cat <<'EOF'
firewall.wan=zone
firewall.wan.name='wan'
firewall.wan.network='wan'
firewall.@zone[1]=zone
firewall.@zone[1].name='lan'
EOF
			;;
		'-q get firewall.wan')
			printf 'zone\n'
			;;
		*) return 1 ;;
	esac
}
got=$(find_wan_zone_section)
[ "$got" = "wan" ] || die "named wan zone expected 'wan', got '$got'"
ok "find_wan_zone_section named zone"

uci() {
	case "$*" in
		'-q show firewall')
			cat <<'EOF'
firewall.@zone[0]=zone
firewall.@zone[0].name='wan'
firewall.@zone[1]=zone
firewall.@zone[1].name='lan'
EOF
			;;
		'-q get firewall.@zone[0]')
			printf 'zone\n'
			;;
		*) return 1 ;;
	esac
}
got=$(find_wan_zone_section)
[ "$got" = "@zone[0]" ] || die "anonymous wan zone expected @zone[0], got '$got'"
ok "find_wan_zone_section anonymous zone"

# Non-zone name=wan before a real zone must not abort lookup.
uci() {
	case "$*" in
		'-q show firewall')
			cat <<'EOF'
firewall.fwd=forwarding
firewall.fwd.name='wan'
firewall.@zone[0]=zone
firewall.@zone[0].name='wan'
EOF
			;;
		'-q get firewall.fwd')
			printf 'forwarding\n'
			;;
		'-q get firewall.@zone[0]')
			printf 'zone\n'
			;;
		*) return 1 ;;
	esac
}
got=$(find_wan_zone_section)
[ "$got" = "@zone[0]" ] || die "skip non-zone name=wan expected @zone[0], got '$got'"
ok "find_wan_zone_section skips non-zone name=wan"

# firewall_changes_pending + enable refuse (issue #168)
PENDING_STAGED=1
UCI_COMMITTED=0
uci() {
	case "$*" in
		'-q changes firewall')
			[ "$PENDING_STAGED" = 1 ] && printf "firewall.@rule[0].name='staged'\n"
			;;
		'-q show firewall')
			printf "firewall.@zone[0]=zone\nfirewall.@zone[0].name='wan'\n"
			;;
		'-q get firewall.@zone[0]')
			printf 'zone\n'
			;;
		'-q get firewall.@zone[0].log')
			printf ''
			;;
		'set firewall.@zone[0].log='*)
			die "uci set must not run when changes pending"
			;;
		'commit firewall')
			UCI_COMMITTED=1
			;;
		*) return 0 ;;
	esac
}
check_nf_log_ipv4() { return 0; }
check_nf_log_ipv6() { return 0; }
acquire_wan_log_lock() { return 0; }
release_wan_log_lock() { return 0; }
out=$(enable_wan_logging)
case "$out" in
	*'"error":"firewall_changes_pending"'*) ;;
	*) die "enable with pending expected firewall_changes_pending, got: $out" ;;
esac
[ "$UCI_COMMITTED" = "0" ] || die "pending enable must not commit"
ok "enable refuses when firewall changes pending"

# restore refuses when pending (does not commit staged delta)
UCI_LOG=()
uci() {
	UCI_LOG+=("$*")
	case "$*" in
		'-q changes firewall') printf "firewall.@rule[0]=rule\n" ;;
		*) return 0 ;;
	esac
}
restore_wan_zone_log '@zone[0]' '' || true
joined="${UCI_LOG[*]}"
case "$joined" in
	*'commit firewall'*) die "restore must not commit while pending: $joined" ;;
esac
ok "restore_wan_zone_log skips commit when pending"
unset -f uci check_nf_log_ipv4 check_nf_log_ipv6 acquire_wan_log_lock release_wan_log_lock

# --- issue #191: TOCTOU between the pending check and `uci commit firewall` --
# UCI staging is global per config file: a non-cooperating writer can stage a
# delta AFTER the toggle's early firewall_changes_pending check but BEFORE the
# commit. The commit gate must re-check at the last moment, abort (fail
# closed), never publish the foreign delta, and never touch the staging area.
#
# Driver models real uci semantics with shell functions:
#   - `changes` is clean on the FIRST call (early check passes) and reports a
#     foreign delta on every later call (the commit-gate re-check) in
#     late_foreign mode — so the pre-#191 code, which has no re-check, sails
#     straight through and commits;
#   - set/delete stage into STAGED_LOG; only a successful commit publishes it
#     to CURRENT_LOG, so post-commit read-backs reflect committed state;
#   - in late_foreign mode any `commit firewall` is a hard FAIL (the foreign
#     delta must never be committed);
#   - in verify_mismatch mode reads always disagree with what we wrote, to
#     drive the post-commit verification warning path.
OUT=''
UCI_CALLS=''
UCI_COMMITS=0
STAGED_LOG='__unset__'
LOGGER_MSGS=''
CHANGES_CALLS=0

# State that must survive subshells (firewall_changes_pending captures uci
# output via $(), and OUT capture runs the toggle in a subshell) is
# file-backed: the changes-call counter (the late_foreign discriminator) and
# the toggle stdout.
FWLIVE_TMP=$(mktemp -d)
trap 'rm -rf "$FWLIVE_TMP"' EXIT
CHANGES_FILE="$FWLIVE_TMP/changes.count"
READ_FILE="$FWLIVE_TMP/reads.count"
OUT_FILE="$FWLIVE_TMP/out"

drive_toggle() {
	op="$1"
	mode="$2"
	OUT=''
	UCI_CALLS=''
	UCI_COMMITS=0
	STAGED_LOG='__unset__'
	LOGGER_MSGS=''
	CHANGES_CALLS=0
	printf '0\n' > "$CHANGES_FILE"
	printf '0\n' > "$READ_FILE"
	CURRENT_LOG="$FWLIVE_CURRENT_LOG"
	uci() {
		UCI_CALLS="$UCI_CALLS|$*"
		case "$*" in
			'-q changes firewall')
				CHANGES_CALLS=$((CHANGES_CALLS + 1))
				_n=0
				[ -f "$CHANGES_FILE" ] && _n=$(cat "$CHANGES_FILE" 2>/dev/null || printf '0')
				_n=$((_n + 1))
				printf '%s\n' "$_n" > "$CHANGES_FILE"
				if [ "$mode" = late_foreign ] && [ "$_n" -ge 2 ]; then
					printf "firewall.@rule[9].name='foreign'\n"
				fi
				;;
			'-q show firewall')
				printf "firewall.@zone[0]=zone\nfirewall.@zone[0].name='wan'\n"
				;;
			'-q get firewall.@zone[0]')
				printf 'zone\n'
				;;
			'-q get firewall.@zone[0].log')
				if [ "$mode" = verify_mismatch ]; then
					# Decision read (1st) returns the real current value so the
					# toggle computes a change; the post-commit verify read
					# (2nd+) returns a mismatching value to drive the warning.
					_rc=0
					[ -f "$READ_FILE" ] && _rc=$(cat "$READ_FILE" 2>/dev/null || printf '0')
					_rc=$((_rc + 1))
					printf '%s\n' "$_rc" > "$READ_FILE"
					if [ "$_rc" -ge 2 ]; then
						printf '9\n'
					else
						printf '%s\n' "$FWLIVE_CURRENT_LOG"
					fi
				elif [ -n "$CURRENT_LOG" ]; then
					printf '%s\n' "$CURRENT_LOG"
				fi
				;;
			'set firewall.@zone[0].log='*)
				STAGED_LOG="${2#*=}"
				;;
			'delete firewall.@zone[0].log')
				STAGED_LOG=''
				;;
			'commit firewall')
				if [ "$mode" = late_foreign ]; then
					die "#191: uci commit issued while a foreign delta was staged"
				fi
				UCI_COMMITS=$((UCI_COMMITS + 1))
				CURRENT_LOG="$STAGED_LOG"
				;;
			*'revert firewall'*)
				die "#191: unexpected revert — abort/mismatch paths must not touch staging or committed data ($*)"
				;;
			*) return 0 ;;
		esac
		return 0
	}
	check_nf_log_ipv4() { return 0; }
	check_nf_log_ipv6() { return 0; }
	acquire_wan_log_lock() { return 0; }
	release_wan_log_lock() { return 0; }
	reload_firewall() { return 0; }
	logger() { LOGGER_MSGS="$LOGGER_MSGS|$*"; }
	if [ "$op" = enable ]; then
		enable_wan_logging > "$OUT_FILE"
	else
		disable_wan_logging > "$OUT_FILE"
	fi
	OUT=$(cat "$OUT_FILE")
	unset -f uci check_nf_log_ipv4 check_nf_log_ipv6 \
		acquire_wan_log_lock release_wan_log_lock reload_firewall logger
}

assert_no_commit_no_stage() {
	label="$1"
	[ "$UCI_COMMITS" -eq 0 ] || die "#191 $label: foreign staged delta got committed ($UCI_COMMITS commit calls)"
	case "$UCI_CALLS" in
		*'set firewall.'*|*'delete firewall.'*) die "#191 $label: log bit staged before abort: $UCI_CALLS" ;;
	esac
	case "$LOGGER_MSGS" in
		*'fwlive'*) ;;
		*) die "#191 $label: abort not reported via logger: $LOGGER_MSGS" ;;
	esac
}

FWLIVE_CURRENT_LOG=''
drive_toggle enable late_foreign
case "$OUT" in
	*'"error":"firewall_changes_pending"'*) ;;
	*) die "#191 enable/late-foreign: expected error firewall_changes_pending, got: $OUT" ;;
esac
assert_no_commit_no_stage "enable/late-foreign"
ok "#191 enable aborts on foreign delta staged at commit time (no commit, no staging)"

FWLIVE_CURRENT_LOG='1'
drive_toggle disable late_foreign
case "$OUT" in
	*'"error":"firewall_changes_pending"'*) ;;
	*) die "#191 disable/late-foreign: expected error firewall_changes_pending, got: $OUT" ;;
esac
assert_no_commit_no_stage "disable/late-foreign"
ok "#191 disable aborts on foreign delta staged at commit time (no commit, no delete)"

FWLIVE_CURRENT_LOG=''
drive_toggle enable verify_mismatch
case "$OUT" in
	'{"ok":true,"changed":true,'*) ;;
	*) die "#191 enable/verify-mismatch: commit must stand (ok:true changed:true), got: $OUT" ;;
esac
[ "$UCI_COMMITS" -eq 1 ] || die "#191 enable/verify-mismatch: expected exactly one commit, got $UCI_COMMITS"
[ "$STAGED_LOG" = '1' ] || die "#191 enable/verify-mismatch: expected log=1 staged, got '$STAGED_LOG'"
case "$LOGGER_MSGS" in
	*'verify FAILED'*) ;;
	*) die "#191 enable/verify-mismatch: missing loud post-commit warning: $LOGGER_MSGS" ;;
esac
ok "#191 post-commit verify mismatch warns loudly, keeps the commit, no blind revert"

FWLIVE_CURRENT_LOG='3'
drive_toggle disable verify_mismatch
case "$OUT" in
	'{"ok":true,"changed":true,'*) ;;
	*) die "#191 disable/verify-mismatch: commit must stand (ok:true changed:true), got: $OUT" ;;
esac
[ "$UCI_COMMITS" -eq 1 ] || die "#191 disable/verify-mismatch: expected exactly one commit, got $UCI_COMMITS"
# clear value for current='3' is 3 & ~1 = 2 (set), not a delete — delete only
# happens when the cleared bit value is 0 (current '1').
[ "$STAGED_LOG" = '2' ] || die "#191 disable/verify-mismatch: expected log=2 staged, got '$STAGED_LOG'"
case "$LOGGER_MSGS" in
	*'verify FAILED'*|*'deleted'*) ;;
	*) die "#191 disable/verify-mismatch: missing loud post-commit warning: $LOGGER_MSGS" ;;
esac
ok "#191 post-commit verify covers the delete case (option must be gone/empty)"

FWLIVE_CURRENT_LOG=''
drive_toggle enable happy
case "$OUT" in
	'{"ok":true,"changed":true,'*) ;;
	*) die "#191 happy enable: expected ok:true changed:true, got: $OUT" ;;
esac
[ "$UCI_COMMITS" -eq 1 ] || die "#191 happy enable: expected exactly one commit, got $UCI_COMMITS"
[ "$STAGED_LOG" = '1' ] || die "#191 happy enable: expected log=1 staged+committed, got '$STAGED_LOG'"
case "$LOGGER_MSGS" in
	*'verify FAILED'*) die "#191 happy enable: spurious verify warning: $LOGGER_MSGS" ;;
esac
ok "#191 happy-path enable still stages + commits the log bit (verify passes)"

FWLIVE_CURRENT_LOG='1'
drive_toggle disable happy
case "$OUT" in
	'{"ok":true,"changed":true,'*) ;;
	*) die "#191 happy disable: expected ok:true changed:true, got: $OUT" ;;
esac
[ "$UCI_COMMITS" -eq 1 ] || die "#191 happy disable: expected exactly one commit, got $UCI_COMMITS"
[ -z "$STAGED_LOG" ] || die "#191 happy disable: expected option deleted, staged '$STAGED_LOG'"
case "$LOGGER_MSGS" in
	*'verify FAILED'*) die "#191 happy disable: spurious verify warning: $LOGGER_MSGS" ;;
esac
ok "#191 happy-path disable still deletes + commits (verify passes)"

sh "$RPCD" __selftest >/dev/null || die "rpcd __selftest"
ok "rpcd __selftest"

echo "fwlive-logging tests passed"

#!/usr/bin/env bash
# Unit tests for fwlive-logging.sh helpers (no UCI/firewall required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGGING_SH="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh"
RPCD="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive"

die() { echo "fwlive-logging test FAIL: $*" >&2; exit 1; }
ok() { echo "fwlive-logging test OK: $*"; }

. "$LOGGING_SH"

type json_escape >/dev/null 2>&1 || die "json_escape must be defined after sourcing logging.sh"
got=$(printf 'a\n\nb' | json_escape)
[ "$got" = "$(printf 'a\\n\\nb')" ] || die "json_escape must keep blank lines, got: $got"
ok "json_escape keeps blank lines"

WAN_LOG_BASELINE_FILE="${FWLIVE_WAN_LOG_BASELINE_FILE:-$(mktemp)}"
export WAN_LOG_BASELINE_FILE
rm -f "$WAN_LOG_BASELINE_FILE"

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
case "$out" in
	*'"warnings":'*) ;;
	*) die "logging_status JSON missing warnings: $out" ;;
esac
ok "build_logging_status_json shape"

# timeout_missing is a warning, not a blocker (openwrt/luci#8992 round 4).
command() {
	case "$1 $2" in
		'-v timeout') return 1 ;;
		*) command command "$@" ;;
	esac
}
check_nf_log_ipv4() { return 0; }
check_nf_log_ipv6() { return 0; }
uci() {
	case "$*" in
		'-q show firewall')
			printf "firewall.@zone[0]=zone\nfirewall.@zone[0].name='wan'\n"
			;;
		'-q get firewall.@zone[0]')
			printf 'zone\n'
			;;
		'-q get firewall.@zone[0].log'|'-q get firewall.@zone[0].log_limit')
			return 1
			;;
		*) return 0 ;;
	esac
}
out=$(build_logging_status_json)
case "$out" in
	*'"warnings":["timeout_missing"]'*) ;;
	*) die "expected timeout_missing in warnings, got: $out" ;;
esac
case "$out" in
	*'"blockers":["timeout_missing"]'*) die "timeout_missing must not appear in blockers: $out" ;;
esac
unset -f command uci check_nf_log_ipv4 check_nf_log_ipv6
ok "timeout_missing warning does not gate logging CTA"

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

# uci -q get miss must not abort WAN discovery under set -e (#291 C3).
uci() {
	case "$*" in
		'-q show firewall')
			cat <<'EOF'
firewall.gone.name='wan'
firewall.@zone[0]=zone
firewall.@zone[0].name='wan'
EOF
			;;
		'-q get firewall.gone')
			return 1
			;;
		'-q get firewall.@zone[0]')
			printf 'zone\n'
			;;
		*) return 1 ;;
	esac
}
got=$(find_wan_zone_section)
[ "$got" = "@zone[0]" ] || die "uci get miss must continue, expected @zone[0], got '$got'"
ok "find_wan_zone_section continues after uci get miss"

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
	REVERTED=0
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
				case "$mode" in
					late_foreign)
						# foreign delta visible from the second changes call on
						[ "$_n" -ge 2 ] && printf "firewall.@rule[9].name='foreign'\n" ;;
					post_stage_foreign)
						# clean through pre-stage gates; foreign appears only
						# once OUR log delta is staged (post-stage check)
						if [ "$STAGED_LOG" != '__unset__' ]; then
							printf "firewall.@rule[9].name='foreign'\n"
						fi
						;;
					post_stage_log_limit_foreign)
						# Same window, but foreign touches log_limit — must not
						# be mistaken for our log= delta (substring trap).
						if [ "$STAGED_LOG" != '__unset__' ]; then
							printf "firewall.@zone[0].log_limit='10/minute'\n"
						fi
						;;
					commit_fail_foreign)
						# clean through pre-stage + post-stage gates (calls 1-3
						# on enable: early + pre-stage + post-stage); foreign
						# appears only when the failure path re-queries
						[ "$_n" -ge 4 ] && printf "firewall.@rule[9].name='foreign'\n" ;;
				esac
				# Real `uci -q changes` also lists OUR staged delta once staged.
				if [ "$STAGED_LOG" != '__unset__' ]; then
					printf "firewall.@zone[0].log='%s'\n" "$STAGED_LOG"
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
				# Matching committed value clears staging (real uci behaviour).
				if [ "$STAGED_LOG" = "$CURRENT_LOG" ]; then
					STAGED_LOG='__unset__'
				fi
				;;
			'delete firewall.@zone[0].log')
				if [ -z "$CURRENT_LOG" ]; then
					STAGED_LOG='__unset__'
				else
					STAGED_LOG=''
				fi
				;;
			'commit firewall')
				case "$mode" in
					late_foreign|post_stage_foreign|post_stage_log_limit_foreign)
						die "#191: uci commit issued while a foreign delta was staged" ;;
					commit_fail_foreign|commit_fail_ours)
						# commit fails; the caller decides whether to revert
						return 1 ;;
				esac
				UCI_COMMITS=$((UCI_COMMITS + 1))
				CURRENT_LOG="$STAGED_LOG"
				;;
			*'revert firewall'*)
				case "$mode" in
					commit_fail_ours) REVERTED=1 ;;
					*) die "#191: unexpected revert — abort/mismatch paths must not touch staging or committed data ($*)" ;;
				esac
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
		*'aborted at commit gate'*) ;;
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
drive_toggle enable post_stage_foreign
case "$OUT" in
	*'firewall_changes_pending'*) ;;
	*) die "#191 enable/post-stage-foreign: expected error firewall_changes_pending, got: $OUT" ;;
esac
[ "$UCI_COMMITS" -eq 0 ] || die "#191 enable/post-stage-foreign: foreign delta got committed"
case "$UCI_CALLS" in
	*'set firewall.'*) ;;
	*) die "#191 enable/post-stage-foreign: expected our log bit to stage before abort: $UCI_CALLS" ;;
esac
case "$LOGGER_MSGS" in
	*'aborted after stage'*) ;;
	*) die "#191 enable/post-stage-foreign: missing after-stage abort log: $LOGGER_MSGS" ;;
esac
[ "$STAGED_LOG" = '__unset__' ] || die "#191 enable/post-stage-foreign: our delta should be undone (STAGED_LOG=$STAGED_LOG)"
ok "#191 enable aborts on foreign delta staged after our set (undo ours, no commit)"

FWLIVE_CURRENT_LOG='1'
drive_toggle disable post_stage_foreign
case "$OUT" in
	*'firewall_changes_pending'*) ;;
	*) die "#191 disable/post-stage-foreign: expected error firewall_changes_pending, got: $OUT" ;;
esac
[ "$UCI_COMMITS" -eq 0 ] || die "#191 disable/post-stage-foreign: foreign delta got committed"
[ "$STAGED_LOG" = '__unset__' ] || die "#191 disable/post-stage-foreign: our delta should be undone (STAGED_LOG=$STAGED_LOG)"
ok "#191 disable aborts on foreign delta staged after our delete (undo ours, no commit)"

FWLIVE_CURRENT_LOG=''
drive_toggle enable post_stage_log_limit_foreign
case "$OUT" in
	*'firewall_changes_pending'*) ;;
	*) die "#191 enable/post-stage-log_limit: expected error firewall_changes_pending, got: $OUT" ;;
esac
[ "$UCI_COMMITS" -eq 0 ] || die "#191 enable/post-stage-log_limit: foreign log_limit delta got committed"
[ "$STAGED_LOG" = '__unset__' ] || die "#191 enable/post-stage-log_limit: our delta should be undone (STAGED_LOG=$STAGED_LOG)"
ok "#191 enable aborts on foreign log_limit staged after our set (exact log= match)"

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

# --- commit-failure paths (#191, CodeRabbit/luna fold) ---
# Commit fails with a FOREIGN delta now visible: must NOT revert (config-wide
# revert would clobber the other writer's staging); warn instead.
FWLIVE_CURRENT_LOG=''
drive_toggle enable commit_fail_foreign
case "$OUT" in
	*'"error":"uci_commit_failed"'*) ;;
	*) die "#191 enable/commit-fail-foreign: expected error uci_commit_failed, got: $OUT" ;;
esac
[ "${REVERTED:-0}" = "0" ] || die "#191 enable/commit-fail-foreign: foreign staging was reverted"
case "$LOGGER_MSGS" in
	*'not reverting'*) ;;
	*) die "#191 enable/commit-fail-foreign: missing not-reverting warning: $LOGGER_MSGS" ;;
esac
ok "#191 commit failure with foreign staging: no revert, warning logged"

# Commit fails with ONLY our own delta staged: revert it so a later toggle is
# not stuck on firewall_changes_pending from our orphaned write.
FWLIVE_CURRENT_LOG=''
drive_toggle enable commit_fail_ours
case "$OUT" in
	*'"error":"uci_commit_failed"'*) ;;
	*) die "#191 enable/commit-fail-ours: expected error uci_commit_failed, got: $OUT" ;;
esac
[ "${REVERTED:-0}" = "1" ] || die "#191 enable/commit-fail-ours: our own orphaned delta was not reverted"
case "$LOGGER_MSGS" in
	*'not reverting'*) die "#191 enable/commit-fail-ours: spurious not-reverting warning: $LOGGER_MSGS" ;;
esac
ok "#191 commit failure with only our delta: revert cleans our orphaned staging"

# WAN log baseline snapshot + restore (uninstall prerm)
BASELINE_WORK=$(mktemp -d)
WAN_LOG_BASELINE_FILE="$BASELINE_WORK/wan-log-baseline"
export WAN_LOG_BASELINE_FILE
WAN_ZONE_LOG=''
uci() {
	case "$1" in
		set)
			_wan_log_key='firewall.@zone[0].log='
			if [ "${2#"$_wan_log_key"}" != "$2" ]; then
				WAN_ZONE_LOG="${2#"$_wan_log_key"}"
			fi
			unset _wan_log_key
			return 0
			;;
		delete)
			[ "$2" = 'firewall.@zone[0].log' ] && WAN_ZONE_LOG=''
			return 0
			;;
		commit) return 0 ;;
	esac
	case "$1 $2" in
		'-q show')
			printf "firewall.@zone[0]=zone\nfirewall.@zone[0].name='wan'\n"
			;;
		'-q get')
			if [ "$3" = 'firewall.@zone[0]' ]; then
				printf 'zone\n'
			elif [ "$3" = 'firewall.@zone[0].log' ]; then
				printf '%s' "$WAN_ZONE_LOG"
			fi
			;;
		'-q changes') return 1 ;;
		'-q delete')
			[ "$3" = 'firewall.@zone[0].log' ] && WAN_ZONE_LOG=''
			;;
		'-q set')
			_wan_log_key='firewall.@zone[0].log='
			if [ "${3#"$_wan_log_key"}" != "$3" ]; then
				WAN_ZONE_LOG="${3#"$_wan_log_key"}"
			fi
			unset _wan_log_key
			;;
		'commit firewall') return 0 ;;
		*) return 0 ;;
	esac
}
reload_firewall() { return 0; }
mkdir() { command mkdir "$@"; }
acquire_wan_log_lock() { return 0; }
release_wan_log_lock() { return 0; }

WAN_ZONE_LOG=''
maybe_snapshot_wan_log_baseline '@zone[0]' || die "snapshot failed"
[ -f "$WAN_LOG_BASELINE_FILE" ] || die "baseline file missing after snapshot"
baseline=$(cat "$WAN_LOG_BASELINE_FILE")
[ -z "$baseline" ] || die "empty baseline expected, got '$baseline'"

WAN_ZONE_LOG='2'
maybe_snapshot_wan_log_baseline '@zone[0]' || die "second snapshot call failed"
baseline=$(cat "$WAN_LOG_BASELINE_FILE")
[ -z "$baseline" ] || die "baseline must not be overwritten (want empty, got '$baseline')"

WAN_ZONE_LOG='1'
restore_wan_log_baseline || die "restore failed"
[ ! -f "$WAN_LOG_BASELINE_FILE" ] || die "baseline file must be removed after restore"
[ -z "$WAN_ZONE_LOG" ] || die "restore empty baseline expected delete, got '$WAN_ZONE_LOG'"
ok "restore_wan_log_baseline clears unset baseline"

WAN_ZONE_LOG='3'
printf '2' >"$WAN_LOG_BASELINE_FILE"
restore_wan_log_baseline || die "restore numeric baseline failed"
[ "$WAN_ZONE_LOG" = "2" ] || die "restore expected log=2, got '$WAN_ZONE_LOG'"
ok "restore_wan_log_baseline sets saved value"

WAN_ZONE_LOG='1'
restore_wan_log_baseline || die "restore no-op failed"
[ "$WAN_ZONE_LOG" = "1" ] || die "missing baseline must not change UCI, got '$WAN_ZONE_LOG'"
ok "restore_wan_log_baseline no-op when baseline absent"

WAN_ZONE_LOG=''
printf '' >"$WAN_LOG_BASELINE_FILE"
restore_wan_log_baseline || die "restore already-at-baseline failed"
[ ! -f "$WAN_LOG_BASELINE_FILE" ] || die "baseline file should be removed when already at target"
ok "restore_wan_log_baseline no-op when UCI already matches baseline"

rm -rf "$BASELINE_WORK"
unset WAN_LOG_BASELINE_FILE WAN_ZONE_LOG BASELINE_WORK
unset -f uci reload_firewall mkdir acquire_wan_log_lock release_wan_log_lock

# --- @zone[N] vs cfgXXXX in uci changes (issue #239) ---
# find_wan_zone_section returns @zone[0]; stock uci often reports staged lines as
# firewall.cfg03dc81.log='1'. wan_log_foreign_staged_lines must treat both as ours.
ZONE_MISMATCH_WORK=$(mktemp -d)
WAN_LOG_BASELINE_FILE="$ZONE_MISMATCH_WORK/wan-log-baseline"
printf '' >"$WAN_LOG_BASELINE_FILE"
PENDING_STAGED=0
CURRENT_LOG=''
uci() {
	case "$*" in
		'-q changes firewall')
			[ "$PENDING_STAGED" = 1 ] && printf "firewall.cfg03dc81.log='1'\n"
			;;
		'-q show firewall')
			printf "firewall.@zone[0]=zone\nfirewall.@zone[0].name='wan'\n"
			;;
		'-q -X show firewall.@zone[0]'|'-q -X show firewall.cfg03dc81')
			printf "firewall.cfg03dc81=zone\n"
			;;
		'-q get firewall.@zone[0]')
			printf 'zone\n'
			;;
		'-q get firewall.@zone[0].name')
			printf 'wan\n'
			;;
		'-q get firewall.@zone[0].log')
			printf '%s' "$CURRENT_LOG"
			;;
		'-q get firewall.cfg03dc81')
			printf 'zone\n'
			;;
		'-q get firewall.cfg03dc81.name')
			printf 'wan\n'
			;;
		'set firewall.@zone[0].log='*)
			PENDING_STAGED=1
			;;
		'commit firewall')
			CURRENT_LOG='1'
			PENDING_STAGED=0
			;;
		*) return 0 ;;
	esac
}
check_nf_log_ipv4() { return 0; }
check_nf_log_ipv6() { return 0; }
acquire_wan_log_lock() { return 0; }
release_wan_log_lock() { return 0; }
reload_firewall() { return 0; }
logger() { return 0; }
out=$(enable_wan_logging)
case "$out" in
	*'"ok":true'*'"changed":true'*) ok "enable succeeds when uci changes resolves zone to cfg id" ;;
	*) die "expected ok:true/changed:true when zone is @zone[0] but changes use cfg id, got: $out" ;;
esac
rm -rf "$ZONE_MISMATCH_WORK"
unset WAN_LOG_BASELINE_FILE PENDING_STAGED CURRENT_LOG ZONE_MISMATCH_WORK
unset -f uci check_nf_log_ipv4 check_nf_log_ipv6 acquire_wan_log_lock release_wan_log_lock reload_firewall logger

# --- #239 staged-line helpers (unit coverage for openwrt/luci#8992 round 4) ---
got=$(wan_log_staged_line_section "firewall.cfg03dc81.log='1'")
[ "$got" = "cfg03dc81" ] || die "staged_line_section set form: expected cfg03dc81 got '$got'"
got=$(wan_log_staged_line_section '-firewall.@zone[1].log')
[ "$got" = "@zone[1]" ] || die "staged_line_section delete form: expected @zone[1] got '$got'"
got=$(wan_log_staged_line_section '- firewall.cfg03dc81.log')
[ "$got" = "cfg03dc81" ] || die "staged_line_section spaced delete form: expected cfg03dc81 got '$got'"
# Near-miss: .log_limit / .log_* must not match the .log= / .log forms (#257).
got=$(wan_log_staged_line_section "firewall.@zone[1].log_limit='10'")
[ -z "$got" ] || die "staged_line_section log_limit near-miss: expected empty got '$got'"
got=$(wan_log_staged_line_section "firewall.@zone[1].log_extra='1'")
[ -z "$got" ] || die "staged_line_section log_extra near-miss: expected empty got '$got'"
ok "wan_log_staged_line_section parses all uci changes forms"

uci() {
	case "$*" in
		'-q -X show firewall.@zone[1]'|'-q -X show firewall.cfg03dc81')
			printf "firewall.cfg03dc81=zone\n"
			;;
		'-q -X show firewall.cfg01aaaa')
			printf "firewall.cfg01aaaa=zone\n"
			;;
		'-q get firewall.@zone[1].name'|'-q get firewall.cfg03dc81.name')
			printf 'wan\n'
			;;
		'-q get firewall.@zone[1]'|'-q get firewall.cfg03dc81')
			printf 'zone\n'
			;;
		'-q get firewall.cfg01aaaa.name')
			printf 'lan\n'
			;;
		'-q get firewall.cfg01aaaa')
			printf 'zone\n'
			;;
		*) return 1 ;;
	esac
}
_staged="firewall.cfg03dc81.log='1'
firewall.cfg01aaaa.log='1'
firewall.@rule[3].target='REJECT'"
_ids=$(wan_log_staged_zone_ids '@zone[1]' "$_staged")
case "$_ids" in
	*'@zone[1]'*|*'cfg03dc81'*) ;;
	*) die "staged_zone_ids expected both WAN ids, got: $_ids" ;;
esac
case "$_ids" in
	*cfg01aaaa*) die "staged_zone_ids must not include lan cfg id: $_ids" ;;
esac
_foreign=$(wan_log_foreign_staged_lines '@zone[1]' "$_staged")
case "$_foreign" in
	*'firewall.cfg01aaaa.log'*) ;;
	*) die "foreign_staged_lines expected lan log line, got: $_foreign" ;;
esac
case "$_foreign" in
	*'@rule[3].target'*) ;;
	*) die "foreign_staged_lines expected rule target line, got: $_foreign" ;;
esac
case "$_foreign" in
	*cfg03dc81*|*'@zone[1].log'*) die "foreign_staged_lines must not flag our WAN log lines: $_foreign" ;;
esac
_ours=$(wan_log_count_our_staged_lines '@zone[1]' "$_staged")
[ "$_ours" = "1" ] || die "count_our_staged_lines expected 1, got '$_ours'"
unset -f uci
ok "wan_log staged-line helpers classify cfg id vs foreign lines"

# B-1: duplicate name=wan zones must NOT be treated as the same section.
# Stub name/type probes too so a class-match revert would fail this test (Grok).
uci() {
	case "$*" in
		'-q -X show firewall.@zone[0]')
			printf "firewall.cfgWAN1=zone\n"
			;;
		'-q -X show firewall.cfgWAN1')
			printf "firewall.cfgWAN1=zone\n"
			;;
		'-q -X show firewall.cfgDUP')
			printf "firewall.cfgDUP=zone\n"
			;;
		'-q get firewall.@zone[0].name'|'-q get firewall.cfgWAN1.name'|'-q get firewall.cfgDUP.name')
			printf 'wan\n'
			;;
		'-q get firewall.@zone[0]'|'-q get firewall.cfgWAN1'|'-q get firewall.cfgDUP')
			printf 'zone\n'
			;;
		*) return 1 ;;
	esac
}
wan_firewall_zone_same '@zone[0]' 'cfgWAN1' \
	|| die "B-1: @zone[0] and its cfg id must still match"
wan_firewall_zone_same '@zone[0]' 'cfgDUP' \
	&& die "B-1: duplicate wan cfgDUP must NOT match @zone[0]"
_staged_dup="firewall.cfgWAN1.log='1'
firewall.cfgDUP.log='0'"
_foreign_dup=$(wan_log_foreign_staged_lines '@zone[0]' "$_staged_dup")
case "$_foreign_dup" in
	*'firewall.cfgDUP.log'*) ;;
	*) die "B-1: foreign_staged_lines must keep duplicate wan .log as foreign, got: $_foreign_dup" ;;
esac
case "$_foreign_dup" in
	*cfgWAN1*) die "B-1: our cfgWAN1.log must not be foreign: $_foreign_dup" ;;
esac
unset -f uci
ok "B-1 duplicate wan zones stay distinct for commit-scope"

# --- Phase 1 (issue #272): timeout presence half + run_with_timeout ---
# Gap 2 presence half: timeout on PATH omits timeout_missing from warnings.
# Round 4 moved timeout_missing from blockers to warnings. Pin the warning.
if command -v timeout >/dev/null 2>&1; then
	check_nf_log_ipv4() { return 0; }
	check_nf_log_ipv6() { return 0; }
	uci() {
		case "$*" in
			'-q show firewall')
				printf "firewall.@zone[0]=zone\nfirewall.@zone[0].name='wan'\n"
				;;
			'-q get firewall.@zone[0]')
				printf 'zone\n'
				;;
			'-q get firewall.@zone[0].log'|'-q get firewall.@zone[0].log_limit')
				return 1
				;;
			*) return 0 ;;
		esac
	}
	out=$(build_logging_status_json)
	case "$out" in
		*timeout_missing*) die "timeout present must omit timeout_missing, got: $out" ;;
	esac
	unset -f uci check_nf_log_ipv4 check_nf_log_ipv6
	ok "timeout present omits timeout_missing from warnings"
else
	ok "timeout present case skipped (no timeout on test host)"
fi

# Gap 3: run_with_timeout contract, tested against the shipped text.
# Exec/timeout halves need a real timeout binary; the fail-closed half
# shadows it via the command stub below and runs everywhere.
_run_with_timeout_src=$(sed -n '/^run_with_timeout()/,/^}/p' "$RPCD")
[ -n "$_run_with_timeout_src" ] || die "run_with_timeout not found in $RPCD"
eval "$_run_with_timeout_src"
unset _run_with_timeout_src
if command -v timeout >/dev/null 2>&1; then
	got=$(run_with_timeout 5 echo hello)
	[ "$got" = "hello" ] || die "run_with_timeout must exec with timeout present, got: $got"
	ok "run_with_timeout execs with timeout present"
	_rc=0
	run_with_timeout 1 sleep 5 2>/dev/null || _rc=$?
	[ "$_rc" -ne 0 ] && [ "$_rc" -ne 127 ] || die "run_with_timeout must time out (non-zero, not 127), got: $_rc"
	ok "run_with_timeout times out without running unbounded"
else
	ok "run_with_timeout exec/timeout skipped (no timeout on test host)"
fi
# command is a shell keyword, so command command reaches the real builtin.
command() {
	case "$1 $2" in
		'-v timeout') return 1 ;;
		*) command command "$@" ;;
	esac
}
got=''
_rc=0
got=$(run_with_timeout 5 echo hello 2>/dev/null) || _rc=$?
[ "$_rc" = "127" ] || die "run_with_timeout without timeout must return 127, got: $_rc"
[ -z "$got" ] || die "run_with_timeout without timeout must not exec, got: $got"
unset -f command
ok "run_with_timeout returns 127 without timeout (fail-closed)"

sh "$RPCD" __selftest >/dev/null || die "rpcd __selftest"
ok "rpcd __selftest"

echo "fwlive-logging tests passed"

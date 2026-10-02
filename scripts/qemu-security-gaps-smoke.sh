#!/usr/bin/env bash
# Lab proofs for honest gaps in docs/developer/security-review.md:
#   1. resolve count/response shape under flood
#   2. flock hold vs enable_wan_logging (BusyBox flock -n retry budget)
#   3. pre-stage firewall_changes_pending refuse (package-commit ride-along = accepted residual)
#
#   ./scripts/qemu-security-gaps-smoke.sh
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-security-gaps-smoke.sh
#
# Prereqs: QEMU guest up with luci-app-fwlive installed (qemu-smoke-fwlive.sh OK).
# Gap 4 (signing keys through validate/publish) is host-side:
#   tests/validate-feed-keys-mode.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
# Lab guests often use ephemeral keys; this script is lab-only.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")
# These bounds leave command/scheduling slack above the five one-second
# acquisition intervals, while keeping an outer guard around the RPC/SSH.
FLOCK_BUDGET_SEC=5
FLOCK_SCHED_SLACK_SEC="${FLOCK_SCHED_SLACK_SEC:-3}"
FLOCK_WAIT_SEC="${FLOCK_WAIT_SEC:-12}"
FLOCK_EXPECTED_MAX_SEC=$((FLOCK_BUDGET_SEC + FLOCK_SCHED_SLACK_SEC))

die() { echo "security-gaps smoke FAIL: $*" >&2; exit 1; }
ok() { echo "security-gaps smoke OK: $*"; }

ssh_guest() {
	# ConnectTimeout bounds setup only — wrap the whole command so a hung
	# guest cannot stall the lab run. The finite lock holder fits this bound.
	timeout "${SSH_TIMEOUT_SEC:-60}" ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

echo "== fwlive security-gaps smoke (root@${HOST}:${PORT}) ==" >&2

command -v timeout >/dev/null 2>&1 \
	|| die "host 'timeout' required (bounds flock/ubus client wait)"

ssh_guest 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU and install fwlive first"
ssh_guest 'command -v ubus >/dev/null && test -x /usr/libexec/rpcd/fwlive' \
	|| die "fwlive rpcd plugin missing"
ssh_guest 'command -v su >/dev/null' \
	|| die "guest 'su' required for unprivileged flock probe"
ssh_guest 'command -v flock >/dev/null' \
	|| die "guest 'flock' required for lock probe (setup, not gap-proven)"

# --- Gap 1: resolve response/count smoke ------------------------------------
# The elapsed budget stops new lookups only; an in-flight helper has no
# application deadline. The host SSH guard bounds this smoke command.
ADDR_JSON='["203.0.113.1","203.0.113.2","203.0.113.3","203.0.113.4","203.0.113.5","203.0.113.6","203.0.113.7","203.0.113.8","203.0.113.9","203.0.113.10","203.0.113.11","203.0.113.12","203.0.113.13","203.0.113.14","203.0.113.15","203.0.113.16","203.0.113.17","203.0.113.18","203.0.113.19","203.0.113.20","203.0.113.21","203.0.113.22","203.0.113.23","203.0.113.24","203.0.113.25","203.0.113.26","203.0.113.27","203.0.113.28","203.0.113.29","203.0.113.30","203.0.113.31","203.0.113.32"]'
START_S="$(date +%s)"
RESOLVE_OUT="$(ssh_guest "ubus call fwlive resolve '{\"addresses\":${ADDR_JSON}}'")" \
	|| die "fwlive.resolve flood failed"
END_S="$(date +%s)"
ELAPSED_SEC=$((END_S - START_S))
[[ -n "$RESOLVE_OUT" ]] || die "resolve flood returned an empty body (probe never ran)"
printf '%s' "$RESOLVE_OUT" | grep -Eq '"error"[[:space:]]*:' \
	&& die "resolve flood replied with error (not gap-proven): $RESOLVE_OUT"
printf '%s' "$RESOLVE_OUT" | grep -Eq '"names"[[:space:]]*:[[:space:]]*\{' \
	|| die "resolve flood missing names object: $RESOLVE_OUT"
NAME_COUNT=$(printf '%s' "$RESOLVE_OUT" | grep -oE '"203\.0\.113\.[0-9]+"' | wc -l) || true
NAME_COUNT=${NAME_COUNT:-0}
NAME_COUNT=${NAME_COUNT//[[:space:]]/}
if printf '%s' "$RESOLVE_OUT" | grep -Eq '"truncated"[[:space:]]*:[[:space:]]*true'; then
	[[ "$NAME_COUNT" -ge 1 ]] \
		|| die "truncated resolve had zero TEST-NET entries (instant refuse?): $RESOLVE_OUT"
else
	[[ "$NAME_COUNT" -eq 32 ]] \
		|| die "resolve expected 32 TEST-NET entries, got ${NAME_COUNT}: $RESOLVE_OUT"
fi
ok "resolve flood returned ${NAME_COUNT} entries in ${ELAPSED_SEC}s"

# --- Gap 2: flock hold vs toggle -------------------------------------------
# Unprivileged UID must not acquire LOCK_EX on the 0600 lock (#167).
# A stuck *root* holder keeps the BusyBox lock busy; fwlive must return
# lock_failed after its five-second acquisition budget, before the host guard.
LOCK_PATH=/etc/fwlive/logging.lock
ssh_guest "test -d /etc/fwlive || mkdir -p /etc/fwlive; touch '$LOCK_PATH'; chmod 0600 '$LOCK_PATH'"

# Unprivileged probe: nobody (or create fwlivegap). Fail closed if no usable user.
UNPRIV_RC="$(ssh_guest '
id nobody >/dev/null 2>&1 || adduser -D -H -s /bin/false fwlivegap >/dev/null || exit 42
USER=nobody
id nobody >/dev/null 2>&1 || USER=fwlivegap
id "$USER" >/dev/null || exit 42
su -s /bin/sh "$USER" -c "flock -n /etc/fwlive/logging.lock true" >/dev/null 2>&1
echo $?
' || echo SETUP_FAIL)"
UNPRIV_RC=$(printf '%s' "$UNPRIV_RC" | tr -d '[:space:]')
case "$UNPRIV_RC" in
	1)
		ok "unprivileged cannot LOCK_EX logging.lock (rc=1)"
		;;
	66)
		provider="$(ssh_guest 'flock --version' 2>/dev/null)" || die "cannot verify denied-open flock provider"
		case "$provider" in
			'flock from util-linux '*) ok "unprivileged cannot open logging.lock (util-linux rc=66)" ;;
			*) die "unprivileged rc=66 without supported util-linux provider (not gap-proven)" ;;
		esac
		;;
	0)
		die "unprivileged flock -n on logging.lock succeeded (expected denial)"
		;;
	127)
		die "unprivileged flock probe: flock not found (setup, not gap-proven)"
		;;
	42|SETUP_FAIL|'')
		die "unprivileged flock probe setup failed (need nobody or adduser + su)"
		;;
	*)
		die "unprivileged flock probe unexpected rc=${UNPRIV_RC} (want 1 or verified util-linux 66; not gap-proven)"
		;;
esac

# Root holder blocks; call enable with host-side timeout (required above).
# Give the guest holder a finite lifetime longer than the client guard. Killing
# only the host SSH process would leave a remote flock/sleep holding fd 9;
# wait for the guest command to finish instead, including on failure.
release_flock_holder() {
	if [[ -n "${HOLDER_PID:-}" ]]; then
		wait "$HOLDER_PID" 2>/dev/null || true
		HOLDER_PID=
	fi
}
ssh_guest "flock '$LOCK_PATH' sleep 20" >/dev/null 2>&1 &
HOLDER_PID=$!
trap release_flock_holder EXIT
sleep 1
START_S="$(date +%s)"
set +e
ENABLE_OUT="$(timeout "${FLOCK_WAIT_SEC}" ssh "${SSH_OPTS[@]}" "root@${HOST}" "ubus call fwlive enable_wan_logging" 2>&1)"
ENABLE_RC=$?
set -e
END_S="$(date +%s)"
ENABLE_ELAPSED=$((END_S - START_S))
release_flock_holder
trap - EXIT

[[ "$ENABLE_RC" -ne 124 ]] \
	|| die "enable remained blocked past ${FLOCK_WAIT_SEC}s host guard (rpcd client timed out)"
printf '%s' "$ENABLE_OUT" | grep -Eq '"error"[[:space:]]*:[[:space:]]*"lock_failed"' \
	|| die "expected bounded lock_failed response under held lock, got (rc=${ENABLE_RC}): $ENABLE_OUT"
[[ "$ENABLE_ELAPSED" -lt "$FLOCK_WAIT_SEC" ]] \
	|| die "bounded lock failure took ${ENABLE_ELAPSED}s (host guard ${FLOCK_WAIT_SEC}s)"
[[ "$ENABLE_ELAPSED" -le "$FLOCK_EXPECTED_MAX_SEC" ]] \
	|| die "bounded lock failure took ${ENABLE_ELAPSED}s (budget ${FLOCK_BUDGET_SEC}s + ${FLOCK_SCHED_SLACK_SEC}s slack)"
[[ "$ENABLE_RC" -eq 0 ]] \
	|| die "unexpected enable under lock hold (rc=${ENABLE_RC}): $ENABLE_OUT"
ok "enable returned lock_failed under held lock in ${ENABLE_ELAPSED}s (<= ${FLOCK_EXPECTED_MAX_SEC}s incl. slack)"

# Ensure lock released for gap 3 — same inode, never rm+recreate. A new inode
# would split serialization with any existing waiter or holder.
if ! ssh_guest "flock -n '$LOCK_PATH' true" >/dev/null 2>&1; then
	RELEASED=0
	for ((_i = 0; _i < 10; _i++)); do
		sleep 1
		if ssh_guest "flock -n '$LOCK_PATH' true" >/dev/null 2>&1; then
			RELEASED=1
			break
		fi
	done
	[[ "$RELEASED" == "1" ]] \
		|| die "logging.lock still held after finite holder exit (will not rm+recreate: stuck holder keeps old inode)"
fi
ok "logging.lock released on the same inode"

# --- Gap 3: foreign firewall staging must not be committed -----------------
ZONE="$(ssh_guest 'ubus call fwlive logging_status 2>/dev/null | jsonfilter -e '\''$.wan_zone'\'' 2>/dev/null || true')"
[[ -n "$ZONE" ]] || die "no WAN zone in firewall config"

# Refuse to wipe operator staging — abort if firewall already has pending changes.
EXISTING_CHANGES="$(ssh_guest 'uci changes firewall 2>/dev/null || true')"
[[ -z "${EXISTING_CHANGES//[$'\t\r\n ']/}" ]] \
	|| die "firewall already has staged changes; abort (will not uci revert): $EXISTING_CHANGES"

# Stage an unrelated option (not the WAN log bit)
MARKER="fwlive_gap_marker_$$"
ssh_guest "uci set firewall.@defaults[0].fwlive_gap_test='${MARKER}'" \
	|| die "could not stage foreign firewall delta"
# Revert only what this script staged — a package-wide revert would discard
# an unrelated delta staged after the empty-state check above.
trap 'ssh_guest "uci revert firewall.@defaults[0].fwlive_gap_test 2>/dev/null || true" >/dev/null 2>&1 || true' EXIT

EN="$(ssh_guest 'ubus call fwlive enable_wan_logging' 2>&1 || true)"
printf '%s' "$EN" | grep -Eq 'firewall_changes_pending' \
	|| die "expected firewall_changes_pending when foreign delta staged; got: $EN"
ok "enable refused with firewall_changes_pending under foreign staging"

# Foreign delta must still be staged (not committed away / not applied as committed-only)
STAGED="$(ssh_guest 'uci changes firewall' || true)"
printf '%s' "$STAGED" | grep -q "$MARKER" \
	|| die "foreign staged marker missing after refuse (uci changes: $STAGED)"
# `uci get` includes staged values — inspect the committed file instead.
COMMITTED="$(ssh_guest "grep -E \"option[[:space:]]+fwlive_gap_test[[:space:]]+'${MARKER}'\" /etc/config/firewall 2>/dev/null || true")"
[[ -z "$COMMITTED" ]] \
	|| die "foreign marker was written into committed /etc/config/firewall"
ok "foreign staged delta neither committed nor dropped by toggle refuse"

ssh_guest "uci revert firewall.@defaults[0].fwlive_gap_test 2>/dev/null || true"
trap - EXIT

echo "== security-gaps smoke passed ==" >&2

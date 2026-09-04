#!/usr/bin/env bash
# Lab proofs for honest gaps in docs/developer/security-review.md:
#   1. resolve wall-clock budget under flood
#   2. flock hold vs enable_wan_logging (BusyBox flock has no -w)
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
# RESOLVE_BUDGET=5 + one in-flight RESOLVE_TIMEOUT=1 → ~6s; allow NTP/SSH slack.
RESOLVE_SLACK_SEC="${RESOLVE_SLACK_SEC:-8}"
FLOCK_WAIT_SEC="${FLOCK_WAIT_SEC:-12}"

die() { echo "security-gaps smoke FAIL: $*" >&2; exit 1; }
ok() { echo "security-gaps smoke OK: $*"; }

ssh_guest() {
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
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

# --- Gap 1: resolve responsiveness (budget smoke) ---------------------------
# Flood with RESOLVE_MAX addresses. This is a wall-clock responsiveness smoke
# against RESOLVE_BUDGET+slack — not a controlled blackhole-DNS proof. Prefer
# non-routable TEST-NET; immediate NXDOMAIN still exercises the loop bound.
ADDR_JSON='["203.0.113.1","203.0.113.2","203.0.113.3","203.0.113.4","203.0.113.5","203.0.113.6","203.0.113.7","203.0.113.8","203.0.113.9","203.0.113.10","203.0.113.11","203.0.113.12","203.0.113.13","203.0.113.14","203.0.113.15","203.0.113.16","203.0.113.17","203.0.113.18","203.0.113.19","203.0.113.20","203.0.113.21","203.0.113.22","203.0.113.23","203.0.113.24","203.0.113.25","203.0.113.26","203.0.113.27","203.0.113.28","203.0.113.29","203.0.113.30","203.0.113.31","203.0.113.32"]'
START_S="$(date +%s)"
ssh_guest "ubus call fwlive resolve '{\"addresses\":${ADDR_JSON}}'" >/dev/null \
	|| die "fwlive.resolve flood failed"
END_S="$(date +%s)"
ELAPSED_SEC=$((END_S - START_S))
[[ "$ELAPSED_SEC" -le "$RESOLVE_SLACK_SEC" ]] \
	|| die "resolve flood took ${ELAPSED_SEC}s (limit ${RESOLVE_SLACK_SEC}s; RESOLVE_BUDGET=5 + lookup slack)"
ok "resolve flood returned in ${ELAPSED_SEC}s (<= ${RESOLVE_SLACK_SEC}s)"

# --- Gap 2: flock hold vs toggle -------------------------------------------
# Unprivileged UID must not acquire LOCK_EX on the 0600 lock (#167).
# A stuck *root* holder blocks BusyBox flock (no -w); ubus client must not
# hang forever — we bound the client wait and record whether rpcd returns.
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
[[ "$UNPRIV_RC" != "SETUP_FAIL" && "$UNPRIV_RC" != "42" && "$UNPRIV_RC" != "" ]] \
	|| die "unprivileged flock probe setup failed (need nobody or adduser + su)"
[[ "$UNPRIV_RC" != "0" ]] \
	|| die "unprivileged flock -n on logging.lock succeeded (expected fail)"
ok "unprivileged cannot LOCK_EX logging.lock (rc=${UNPRIV_RC})"

# Root holder blocks; call enable with host-side timeout (required above).
ssh_guest "flock '$LOCK_PATH' sleep 120" >/dev/null 2>&1 &
HOLDER_PID=$!
sleep 1
set +e
ENABLE_OUT="$(timeout "${FLOCK_WAIT_SEC}" ssh "${SSH_OPTS[@]}" "root@${HOST}" "ubus call fwlive enable_wan_logging" 2>&1)"
ENABLE_RC=$?
set -e
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
# Release any leftover lock from the sleep if still held
ssh_guest "flock -u '$LOCK_PATH' true 2>/dev/null || true; true" >/dev/null 2>&1 || true

if [[ "$ENABLE_RC" -eq 124 ]]; then
	# Client timeout fired — rpcd worker still blocked on flock (accepted residual:
	# BusyBox flock has no -w; document as proven observation, not a pass).
	ok "stuck root flock holder: ubus client timed out after ${FLOCK_WAIT_SEC}s (rpcd not bounded by flock -w; residual holds)"
	echo "security-gaps NOTE: flock/rpcd bound = residual (BusyBox no flock -w); proof class stays documented" >&2
elif printf '%s' "$ENABLE_OUT" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*(true|false)'; then
	ok "enable returned while lock contention resolved or failed closed: $ENABLE_OUT"
else
	die "unexpected enable under lock hold (rc=${ENABLE_RC}): $ENABLE_OUT"
fi

# Ensure lock released for gap 3
ssh_guest "flock -n '$LOCK_PATH' true" >/dev/null 2>&1 \
	|| ssh_guest "rm -f '$LOCK_PATH'; mkdir -p /etc/fwlive; touch '$LOCK_PATH'; chmod 0600 '$LOCK_PATH'"

# --- Gap 3: foreign firewall staging must not be committed -----------------
ZONE="$(ssh_guest "uci -q show firewall | sed -n \"s/^firewall\\.\\([^.]*\\)\\.name='wan'\$/\\1/p\" | head -1")"
[[ -n "$ZONE" ]] || die "no WAN zone in firewall config"

# Refuse to wipe operator staging — abort if firewall already has pending changes.
EXISTING_CHANGES="$(ssh_guest 'uci changes firewall 2>/dev/null || true')"
[[ -z "${EXISTING_CHANGES//[$'\t\r\n ']/}" ]] \
	|| die "firewall already has staged changes; abort (will not uci revert): $EXISTING_CHANGES"

# Stage an unrelated option (not the WAN log bit)
MARKER="fwlive_gap_marker_$$"
ssh_guest "uci set firewall.@defaults[0].fwlive_gap_test='${MARKER}'" \
	|| die "could not stage foreign firewall delta"

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

ssh_guest 'uci revert firewall 2>/dev/null || true'

echo "== security-gaps smoke passed ==" >&2

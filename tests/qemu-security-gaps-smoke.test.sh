#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Deterministic host harness for qemu-security-gaps-smoke.sh.
# Distinguishes gap-proven from probe-never-ran (#595). Does not claim a live QEMU run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/qemu-security-gaps-smoke.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() { echo "qemu security-gaps smoke test FAIL: $*" >&2; exit 1; }
ok() { echo "qemu security-gaps smoke test OK: $*"; }

mkdir -p "$TMP/bin"

cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -u
cmd="${!#}"

if [[ "$cmd" == "echo connected" ]]; then
	printf '%s\n' connected
	exit 0
fi
if [[ "$cmd" == *"command -v ubus"* ]]; then
	exit 0
fi
if [[ "$cmd" == *"command -v su"* ]]; then
	exit 0
fi
if [[ "$cmd" == *"command -v flock"* ]]; then
	if [[ "${FWLIVE_STUB_FLOCK:-present}" == missing ]]; then
		exit 1
	fi
	printf '%s\n' /usr/bin/flock
	exit 0
fi
if [[ "$cmd" == *"fwlive.resolve"* || "$cmd" == *"ubus call fwlive resolve"* ]]; then
	case "${FWLIVE_STUB_RESOLVE:-ok}" in
		empty)
			exit 0
			;;
		error)
			printf '%s\n' '{"names":{},"error":"no_resolver"}'
			exit 0
			;;
		zero)
			printf '%s\n' '{"names":{}}'
			exit 0
			;;
		ok|*)
			# Rebuilt here so the stub file stays self-contained.
			out='{'
			sep=
			for i in $(seq 1 32); do
				out="${out}${sep}\"203.0.113.${i}\":\"\""
				sep=,
			done
			printf '{"names":%s}\n' "${out}}"
			exit 0
			;;
	esac
fi
if [[ "$cmd" == *"mkdir -p /etc/fwlive"* || "$cmd" == *"chmod 0600"* ]]; then
	exit 0
fi
if [[ "$cmd" == *"id nobody"* || "$cmd" == *"flock -n /etc/fwlive/logging.lock true"* ]]; then
	printf '%s\n' "${FWLIVE_STUB_UNPRIV_RC:-1}"
	exit 0
fi
if [[ "$cmd" == *"flock "*"/etc/fwlive/logging.lock"* && "$cmd" == *"sleep"* ]]; then
	exit 0
fi
if [[ "$cmd" == *"ubus call fwlive enable_wan_logging"* ]]; then
	if [[ "${FWLIVE_STUB_STAGED:-0}" == 1 ]]; then
		printf '%s\n' '{"ok":false,"error":"firewall_changes_pending"}'
		exit 0
	fi
	printf '%s\n' '{"ok":false,"error":"lock_failed"}'
	exit 0
fi
if [[ "$cmd" == *"flock -n"* && "$cmd" == *"logging.lock"* ]]; then
	exit 0
fi
if [[ "$cmd" == *"ubus call fwlive logging_status"* ]]; then
	printf '%s\n' '{"wan_zone":"wan","wan_log":false}'
	exit 0
fi
if [[ "$cmd" == *"uci changes firewall"* ]]; then
	if [[ "${FWLIVE_STUB_STAGED:-0}" == 1 ]]; then
		printf '%s\n' "firewall.@defaults[0].fwlive_gap_test='${FWLIVE_STUB_MARKER:-marker}'"
	fi
	exit 0
fi
if [[ "$cmd" == *"uci set firewall.@defaults[0].fwlive_gap_test="* ]]; then
	exit 0
fi
if [[ "$cmd" == *"uci revert"* ]]; then
	exit 0
fi
if [[ "$cmd" == *"grep -E"* && "$cmd" == *"/etc/config/firewall"* ]]; then
	exit 0
fi
exit 0
EOF
chmod 755 "$TMP/bin/ssh"

cat >"$TMP/bin/timeout" <<'EOF'
#!/usr/bin/env bash
set -u
shift
if [[ "${FWLIVE_STUB_ENABLE:-ok}" == timeout && "$*" == *enable_wan_logging* ]]; then
	exit 124
fi
exec "$@"
EOF
chmod 755 "$TMP/bin/timeout"

cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$TMP/bin/sleep"

run_gaps() {
	local label="$1"
	local output="$TMP/${label}.log"
	if PATH="$TMP/bin:$PATH" OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 \
		FWLIVE_STUB_RESOLVE="${FWLIVE_STUB_RESOLVE:-ok}" \
		FWLIVE_STUB_FLOCK="${FWLIVE_STUB_FLOCK:-present}" \
		FWLIVE_STUB_UNPRIV_RC="${FWLIVE_STUB_UNPRIV_RC:-1}" \
		FWLIVE_STUB_ENABLE="${FWLIVE_STUB_ENABLE:-ok}" \
		FWLIVE_STUB_STAGED="${FWLIVE_STUB_STAGED:-0}" \
		bash "$SCRIPT" >"$output" 2>&1; then
		return 0
	fi
	return 1
}

bash -n "$SCRIPT" || die 'qemu-security-gaps-smoke.sh has invalid shell syntax'
ok 'script syntax'

if (FWLIVE_STUB_RESOLVE=error; export FWLIVE_STUB_RESOLVE; run_gaps resolve-error); then
	die 'instant resolve error JSON passed as gap-proven'
fi
grep -Fq 'resolve flood replied with error' "$TMP/resolve-error.log" \
	|| die 'error JSON was not reported as not gap-proven'
ok 'instant resolve refuse (error JSON) fails gap 1'

if (FWLIVE_STUB_RESOLVE=empty; export FWLIVE_STUB_RESOLVE; run_gaps resolve-empty); then
	die 'empty resolve body passed as gap-proven'
fi
grep -Fq 'empty body' "$TMP/resolve-empty.log" \
	|| die 'empty resolve body was not reported'
ok 'empty resolve body fails gap 1'

if (FWLIVE_STUB_RESOLVE=zero; export FWLIVE_STUB_RESOLVE; run_gaps resolve-zero); then
	die 'zero-name resolve passed as gap-proven'
fi
grep -Fq 'expected 32 TEST-NET entries' "$TMP/resolve-zero.log" \
	|| die 'zero-name resolve was not reported'
ok 'zero-name resolve fails gap 1'

if (FWLIVE_STUB_FLOCK=missing; export FWLIVE_STUB_FLOCK; run_gaps flock-missing); then
	die 'missing flock passed as gap-proven'
fi
grep -Fq "guest 'flock' required" "$TMP/flock-missing.log" \
	|| die 'missing flock was not reported as setup'
ok 'missing flock is a setup error'

if (FWLIVE_STUB_UNPRIV_RC=127; export FWLIVE_STUB_UNPRIV_RC; run_gaps unpriv-127); then
	die 'unprivileged rc=127 passed as gap-proven'
fi
grep -Fq 'flock not found' "$TMP/unpriv-127.log" \
	|| die 'rc=127 was not reported as setup'
ok 'unprivileged rc=127 is a setup error'

if (FWLIVE_STUB_UNPRIV_RC=0; export FWLIVE_STUB_UNPRIV_RC; run_gaps unpriv-0); then
	die 'unprivileged flock success passed'
fi
grep -Fq 'succeeded' "$TMP/unpriv-0.log" \
	|| die 'unprivileged success was not reported'
ok 'unprivileged flock success fails gap 2'

FWLIVE_STUB_ENABLE=timeout run_gaps enable-timeout || true
grep -Fq 'security-gaps RESIDUAL' "$TMP/enable-timeout.log" \
	|| die 'timeout was not recorded as residual'
if grep -Fq 'smoke OK: stuck root flock holder' "$TMP/enable-timeout.log"; then
	die 'timeout was labeled as a pass'
fi
ok 'client timeout is residual, not a pass'

# Happy path: stage after the unprivileged probe so gap 3 sees the marker.
# The script stages mid-run; the ssh stub treats FWLIVE_STUB_STAGED as static.
# Re-run with a wrapper that flips STAGED when uci set is seen — implemented
# in the ssh stub via a side file.
cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -u
cmd="${!#}"
staged_file="${FWLIVE_STUB_STAGED_FILE:-/tmp/fwlive-gaps-staged}"

if [[ "$cmd" == "echo connected" ]]; then
	printf '%s\n' connected
	exit 0
fi
if [[ "$cmd" == *"command -v "* ]]; then
	exit 0
fi
if [[ "$cmd" == *"ubus call fwlive resolve"* ]]; then
	out='{'
	sep=
	for i in $(seq 1 32); do
		out="${out}${sep}\"203.0.113.${i}\":\"\""
		sep=,
	done
	printf '{"names":%s}\n' "${out}}"
	exit 0
fi
if [[ "$cmd" == *"id nobody"* || "$cmd" == *"flock -n /etc/fwlive/logging.lock true"* ]]; then
	printf '%s\n' 1
	exit 0
fi
if [[ "$cmd" == *"ubus call fwlive enable_wan_logging"* ]]; then
	if [[ -f "$staged_file" ]]; then
		printf '%s\n' '{"ok":false,"error":"firewall_changes_pending"}'
	else
		printf '%s\n' '{"ok":false,"error":"lock_failed"}'
	fi
	exit 0
fi
if [[ "$cmd" == *"ubus call fwlive logging_status"* ]]; then
	printf '%s\n' '{"wan_zone":"wan","wan_log":false}'
	exit 0
fi
if [[ "$cmd" == *"uci set firewall.@defaults[0].fwlive_gap_test="* ]]; then
	printf '%s\n' "$cmd" > "$staged_file"
	exit 0
fi
if [[ "$cmd" == *"uci changes firewall"* ]]; then
	if [[ -f "$staged_file" ]]; then
		val=$(sed -n "s/.*fwlive_gap_test='\\([^']*\\)'.*/\\1/p" "$staged_file")
		printf '%s\n' "firewall.@defaults[0].fwlive_gap_test='${val}'"
	fi
	exit 0
fi
if [[ "$cmd" == *"uci revert"* ]]; then
	rm -f "$staged_file"
	exit 0
fi
exit 0
EOF
chmod 755 "$TMP/bin/ssh"

rm -f "$TMP/staged"
if PATH="$TMP/bin:$PATH" OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 \
	FWLIVE_STUB_STAGED_FILE="$TMP/staged" \
	bash "$SCRIPT" >"$TMP/happy.log" 2>&1; then
	:
else
	die "happy-path smoke failed: $(cat "$TMP/happy.log")"
fi
grep -Fq 'resolve flood returned 32 entries' "$TMP/happy.log" \
	|| die 'happy path did not prove 32 resolve entries'
grep -Fq 'unprivileged cannot LOCK_EX logging.lock (rc=1)' "$TMP/happy.log" \
	|| die 'happy path did not prove unprivileged rc=1'
grep -Fq 'security-gaps smoke passed' "$TMP/happy.log" \
	|| die 'happy path did not reach overall pass'
ok 'positive control: 32 resolve entries and unprivileged rc=1'

echo 'qemu security-gaps smoke tests passed'

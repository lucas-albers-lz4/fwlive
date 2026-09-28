#!/usr/bin/env bash
# Source-contract checks for qemu-wait-guest.sh (#839) and validate-feed-smoke.sh (#838).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT="$ROOT/scripts/qemu-wait-guest.sh"
SMOKE="$ROOT/scripts/validate-feed-smoke.sh"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[[ -x "$WAIT" ]] || fail "qemu-wait-guest.sh is not executable"
[[ -x "$SMOKE" ]] || fail "validate-feed-smoke.sh is not executable"
bash -n "$WAIT" || fail "qemu-wait-guest.sh syntax"
bash -n "$SMOKE" || fail "validate-feed-smoke.sh syntax"

err=""
if err="$("$WAIT" --cmd 2>&1)"; then
	fail "--cmd without a value must fail"
fi
[[ "$err" == *"usage: qemu-wait-guest.sh --cmd CMD"* ]] ||
	fail "--cmd without a value must print usage (got: $err)"

grep -Fq 'BatchMode=yes' "$WAIT" || fail "wait must set BatchMode=yes"
grep -Fq 'NumberOfPasswordPrompts=0' "$WAIT" || fail "wait must disable password prompts"

grep -Fq 'cleanup_on_fail' "$SMOKE" || fail "feed smoke must define cleanup_on_fail"
grep -Fq 'trap cleanup_on_fail EXIT' "$SMOKE" || fail "feed smoke must trap EXIT"
grep -Fq 'validate_matrix_stop_qemu' "$SMOKE" || fail "feed smoke cleanup must stop QEMU"

if err="$(MAX_WAIT=abc "$WAIT" 2>&1)"; then
	fail "MAX_WAIT=abc must fail"
fi
[[ "$err" == *"invalid MAX_WAIT"* ]] || fail "MAX_WAIT=abc must name the field (got: $err)"

if err="$(INTERVAL=0 "$WAIT" 2>&1)"; then
	fail "INTERVAL=0 must fail"
fi
[[ "$err" == *"invalid INTERVAL"* ]] || fail "INTERVAL=0 must name the field (got: $err)"

if err="$(OPENWRT_SSH_PORT=abc "$WAIT" 2>&1)"; then
	fail "OPENWRT_SSH_PORT=abc must fail"
fi
[[ "$err" == *"invalid OPENWRT_SSH_PORT"* ]] || fail "bad SSH port must name the field (got: $err)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SSH_LOG"
remote="${!#}"
case "${SSH_BEHAVIOR:-ready}" in
	fail)
		echo "connection refused" >&2
		exit 255
		;;
	drop-command)
		if [[ "$remote" == "echo READY" ]]; then
			echo READY
			exit 0
		fi
		echo "connection lost" >&2
		exit 255
		;;
	missing-marker)
		if [[ "$remote" == "echo READY" ]]; then
			echo READY
			exit 0
		fi
		echo 123
		exit 0
		;;
	hang-probe)
		if [[ "$remote" == "echo READY" ]]; then
			exec /bin/sleep 10
		fi
		exec /bin/sh -c "$remote"
		;;
	slow-probe)
		if [[ "$remote" == "echo READY" ]]; then
			/bin/sleep 1
			echo READY
			exit 0
		fi
		exec /bin/sh -c "$remote"
		;;
	ready)
		if [[ "$remote" == "echo READY" ]]; then
			echo READY
			exit 0
		fi
		exec /bin/sh -c "$remote"
		;;
	*)
		exit 2
		;;
esac
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$SLEEP_LOG"
exec /bin/sleep "$1"
EOF
chmod +x "$tmp/bin/ssh" "$tmp/bin/sleep"

if output="$(PATH="$tmp/bin:$PATH" SSH_BEHAVIOR=fail SSH_LOG="$tmp/ssh.log" SLEEP_LOG="$tmp/sleep.log" \
	MAX_WAIT=1 INTERVAL=120 "$WAIT" 2>&1)"; then
	fail "failed SSH probe must time out"
else
	status=$?
fi
[[ "$status" -eq 1 ]] || fail "failed SSH probe must exit 1 (got $status)"
[[ "$output" == *"SSH probe failed"* && "$output" == *"readiness probe did not succeed"* ]] ||
	fail "probe failure should be reported as SSH readiness failure (got: $output)"
grep -Eq 'ConnectTimeout=1([[:space:]]|$)' "$tmp/ssh.log" ||
	fail "ConnectTimeout must not exceed the one-second remaining deadline"
sleep_arg="$(cat "$tmp/sleep.log")"
[[ "$sleep_arg" =~ ^[0-9]+$ ]] || fail "a numeric bounded sleep must be used (got: $sleep_arg)"
[[ "$sleep_arg" -le 1 ]] || fail "sleep must be capped to remaining time (got $sleep_arg)"

if output="$(PATH="$tmp/bin:$PATH" SSH_BEHAVIOR=hang-probe SSH_LOG="$tmp/ssh.log" SLEEP_LOG="$tmp/sleep.log" \
	MAX_WAIT=1 INTERVAL=120 "$WAIT" 2>&1)"; then
	fail "a connected SSH probe that hangs must time out"
else
	status=$?
fi
[[ "$status" -eq 1 ]] || fail "a hanging readiness probe must exit 1 (got $status)"
[[ "$output" == *"SSH readiness probe timed out after 1s"* ]] ||
	fail "a connected hanging probe must be identified as a timeout (got: $output)"

for command_status in 7 255; do
	: >"$tmp/ssh.log"
	if output="$(PATH="$tmp/bin:$PATH" SSH_BEHAVIOR=ready SSH_LOG="$tmp/ssh.log" SLEEP_LOG="$tmp/sleep.log" \
		"$WAIT" --cmd "printf 'cmd output'; exit $command_status" 2>&1)"; then
		status=0
	else
		status=$?
	fi
	[[ "$status" -eq "$command_status" ]] ||
		fail "remote command exit $command_status must be preserved (got $status; $output)"
	[[ "$output" == *"remote command exited with status $command_status"* ]] ||
		fail "remote command failure must be distinguished (got: $output)"
	[[ "$output" == *"cmd output"* ]] || fail "remote command output must be preserved (got: $output)"
	[[ "$output" != *"SSH transport failed"* ]] || fail "remote exit $command_status is not a transport failure"
	[[ "$(wc -l <"$tmp/ssh.log")" -eq 2 ]] || fail "--cmd must run once after one readiness probe"
done

: >"$tmp/ssh.log"
if output="$(PATH="$tmp/bin:$PATH" SSH_BEHAVIOR=slow-probe SSH_LOG="$tmp/ssh.log" SLEEP_LOG="$tmp/sleep.log" \
	MAX_WAIT=5 INTERVAL=1 "$WAIT" --cmd 'printf command-ok' 2>&1)"; then
	status=0
else
	status=$?
fi
[[ "$status" -eq 0 ]] || fail "successful post-probe command must pass (got $status; $output)"
first_connect_timeout="$(sed -n '1s/.*ConnectTimeout=\([0-9][0-9]*\).*/\1/p' "$tmp/ssh.log")"
command_connect_timeout="$(sed -n '2s/.*ConnectTimeout=\([0-9][0-9]*\).*/\1/p' "$tmp/ssh.log")"
[[ -n "$first_connect_timeout" && -n "$command_connect_timeout" ]] ||
	fail "readiness and command SSH calls must both set ConnectTimeout"
[[ "$command_connect_timeout" -lt "$first_connect_timeout" ]] ||
	fail "command ConnectTimeout must be recomputed after readiness time is consumed"

: >"$tmp/ssh.log"
if output="$(PATH="$tmp/bin:$PATH" SSH_BEHAVIOR=drop-command SSH_LOG="$tmp/ssh.log" SLEEP_LOG="$tmp/sleep.log" \
	"$WAIT" --cmd 'touch /tmp/fwlive-wait-command-marker' 2>&1)"; then
	fail "transport failure while running --cmd must fail"
else
	status=$?
fi
[[ "$status" -eq 1 ]] || fail "command transport failure must exit 1 (got $status)"
[[ "$output" == *"SSH transport failed while running --cmd"* ]] ||
	fail "command transport failure must be distinguished (got: $output)"
[[ "$(wc -l <"$tmp/ssh.log")" -eq 2 ]] || fail "failed --cmd transport must not retry the command"

if output="$(PATH="$tmp/bin:$PATH" SSH_BEHAVIOR=missing-marker SSH_LOG="$tmp/ssh.log" SLEEP_LOG="$tmp/sleep.log" \
	"$WAIT" --cmd 'printf 123' 2>&1)"; then
	fail "missing remote command status marker must fail"
else
	status=$?
fi
[[ "$status" -eq 1 ]] || fail "missing remote status marker must exit 1 (got $status)"
[[ "$output" == *"without its status marker"* ]] ||
	fail "missing marker must not treat numeric command output as an exit code (got: $output)"

echo "qemu-wait-guest / validate-feed-smoke tests passed"

#!/usr/bin/env bash
# Source-contract checks for qemu-wait-guest.sh (#839 #1007 #1009) and validate-feed-smoke.sh (#838).
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
REAL_TIMEOUT="$(command -v timeout || true)"
[[ -n "$REAL_TIMEOUT" ]] || fail "qemu-wait guest tests require the documented host timeout utility"
TIMEOUT_LOG="$tmp/timeout.log"
export REAL_TIMEOUT TIMEOUT_LOG
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
	hang-command)
		if [[ "$remote" == "echo READY" ]]; then
			echo READY
			exit 0
		fi
		exec /bin/sleep 10
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
cat >"$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TIMEOUT_LOG"
exec "$REAL_TIMEOUT" "$@"
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$SLEEP_LOG"
exec /bin/sleep "$1"
EOF
chmod +x "$tmp/bin/ssh" "$tmp/bin/sleep"
chmod +x "$tmp/bin/timeout"

# Missing host timeout must fail closed with a package hint.
mkdir -p "$tmp/no-timeout-bin"
ln -s "$(command -v dirname)" "$tmp/no-timeout-bin/dirname"
if output="$(PATH="$tmp/no-timeout-bin" /bin/bash "$WAIT" 2>&1)"; then
	fail "missing host timeout must fail"
fi
[[ "$output" == *"timeout command is required"* && "$output" == *"sudo apt install coreutils"* ]] ||
	fail "missing timeout must include an install hint (got: $output)"

# Control only this sleep-clamping case's clock. With real Bash SECONDS, a
# one-second deadline can expire during the failed probe, legitimately skipping
# sleep altogether. Unsetting SECONDS removes its special clock behavior.
# The hanging-probe and hanging-command cases below still use real time.
# Variables in the script expand in the child Bash.
# shellcheck disable=SC2016
if output="$(PATH="$tmp/bin:$PATH" SSH_BEHAVIOR=fail SSH_LOG="$tmp/ssh.log" SLEEP_LOG="$tmp/sleep.log" \
	MAX_WAIT=1 INTERVAL=120 FWLIVE_WAIT_SCRIPT="$WAIT" "$REAL_TIMEOUT" -s KILL 5s /bin/bash -c '
		unset SECONDS
		SECONDS=0
		sleep() {
			printf "%s\n" "$1" >> "$SLEEP_LOG"
			SECONDS=$((SECONDS + $1))
		}
		source "$FWLIVE_WAIT_SCRIPT"
	' 2>&1)"; then
	fail "failed SSH probe must time out"
else
	status=$?
fi
[[ "$status" -ne 137 ]] || fail "controlled-clock probe exceeded its five-second safety deadline"
[[ "$status" -eq 1 ]] || fail "failed SSH probe must exit 1 (got $status)"
[[ "$output" == *"SSH probe failed"* && "$output" == *"readiness probe did not succeed"* ]] ||
	fail "probe failure should be reported as SSH readiness failure (got: $output)"
grep -Eq 'ConnectTimeout=1([[:space:]]|$)' "$tmp/ssh.log" ||
	fail "ConnectTimeout must not exceed the one-second remaining deadline"
sleep_arg="$(cat "$tmp/sleep.log")"
[[ "$sleep_arg" =~ ^[0-9]+$ ]] || fail "a numeric bounded sleep must be used (got: $sleep_arg)"
[[ "$sleep_arg" -eq 1 ]] || fail "sleep must equal the one-second remaining budget (got $sleep_arg)"

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
: >"$TIMEOUT_LOG"
command_started=$SECONDS
if output="$(PATH="$tmp/bin:$PATH" SSH_BEHAVIOR=hang-command SSH_LOG="$tmp/ssh.log" SLEEP_LOG="$tmp/sleep.log" \
	MAX_WAIT=4 INTERVAL=1 "$WAIT" --cmd 'sleep 30' 2>&1)"; then
	fail "a hung remote --cmd must be bounded by MAX_WAIT"
else
	status=$?
fi
command_elapsed=$((SECONDS - command_started))
[[ "$status" -eq 1 ]] || fail "hung --cmd must exit 1 (got $status; $output)"
[[ "$output" == *"--cmd SSH timed out within the remaining MAX_WAIT budget"* ]] ||
	fail "hung --cmd must be identified as a timeout (got: $output)"
[[ "$(wc -l <"$tmp/ssh.log")" -eq 2 ]] || fail "hung --cmd must run once after one readiness probe"
[[ "$(wc -l <"$TIMEOUT_LOG")" -eq 2 ]] || fail "readiness and --cmd SSH must both use timeout"
command_timeout="$(sed -n '2p' "$TIMEOUT_LOG")"
[[ "$command_timeout" =~ ^-s\ KILL\ ([1-4])s\ ssh\  ]] ||
	fail "--cmd timeout must use the remaining MAX_WAIT budget (got: $command_timeout)"
[[ "$command_elapsed" -le 5 ]] ||
	fail "hung --cmd exceeded its MAX_WAIT budget by more than one shell second (${command_elapsed}s)"

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

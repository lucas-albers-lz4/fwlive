#!/usr/bin/env bash
# PID-file stop, start liveness probe, and env-passed feed URLs (#815 #805 #808 #986).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/qemu-lab-net.sh
source "${ROOT}/scripts/lib/qemu-lab-net.sh"
# shellcheck source=scripts/lib/validate-matrix.sh
source "${ROOT}/scripts/lib/validate-matrix.sh"

X86="$ROOT/scripts/run-openwrt-x86-qemu.sh"
ARMSR="$ROOT/scripts/run-openwrt-armsr-armv8-qemu.sh"
INSTALL="$ROOT/scripts/qemu-install-from-feed.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
	echo "qemu-lifecycle test FAIL: $*" >&2
	exit 1
}

bash -n "$X86" || fail "x86 runner syntax"
bash -n "$ARMSR" || fail "armsr runner syntax"
bash -n "${ROOT}/scripts/lib/qemu-lab-net.sh" || fail "qemu-lab-net.sh syntax"
bash -n "${ROOT}/scripts/lib/validate-matrix.sh" || fail "validate-matrix.sh syntax"

grep -Fq -- '-pidfile' "$X86" || fail "x86 runner must pass -pidfile"
grep -Fq -- '-pidfile' "$ARMSR" || fail "armsr runner must pass -pidfile"
grep -Fq 'qemu_lab_stop_guest' "$X86" || fail "x86 --stop must use qemu_lab_stop_guest"
grep -Fq 'qemu_lab_stop_guest' "$ARMSR" || fail "armsr --stop must use qemu_lab_stop_guest"
if grep -nE '^\s*pkill -f' "$X86" "$ARMSR"; then
	fail "runners must not pkill directly; qemu_lab_stop_guest owns --force"
fi
grep -Fq 'uname -s' "$X86" || fail "x86 runner must gate on Linux uname -s"
hint="$(qemu_lab_port_owners_hint)"
[[ "$hint" == *"run-openwrt-x86-qemu.sh --stop --force"* ]] || fail "port hint must say x86 --stop --force"
[[ "$hint" == *"run-openwrt-armsr-armv8-qemu.sh --stop --force"* ]] || fail "port hint must say armsr --stop --force"
grep -Fq 'qemu_lab_parse_runner_args' "$X86" || fail "x86 must parse --stop/--force via qemu_lab_parse_runner_args"
grep -Fq 'qemu_lab_parse_runner_args' "$ARMSR" || fail "armsr must parse --stop/--force via qemu_lab_parse_runner_args"

grep -Fq 'validate_matrix_assert_qemu_up' "${ROOT}/scripts/lib/validate-matrix.sh" \
	|| fail "validate-matrix must define validate_matrix_assert_qemu_up"
grep -Fq 'child_pid=$!' "${ROOT}/scripts/lib/validate-matrix.sh" \
	|| fail "start_qemu must capture the child PID"
stop_fn="$(sed -n '/^validate_matrix_stop_qemu()/,/^}/p' "${ROOT}/scripts/lib/validate-matrix.sh")"
if printf '%s\n' "$stop_fn" | grep -Fq '2>/dev/null'; then
	fail "validate_matrix_stop_qemu must not swallow stop output"
fi
if printf '%s\n' "$stop_fn" | grep -Fq '|| true'; then
	fail "validate_matrix_stop_qemu must not ignore stop failures"
fi

grep -Fq 'ssh_run_env' "$INSTALL" || fail "feed installer must use ssh_run_env"
grep -Fq "sh -c \"'\${script}'\"" "$INSTALL" \
	|| fail "ssh_run_env must run the command under sh -c so env expands after set"
if grep -Eq "wget -O /tmp/fwlive-feed\.(key|rsa\.pub) '" "$INSTALL"; then
	fail "feed installer must not interpolate URLs into wget"
fi
unset FWLIVE_OPKG_KEY_URL
empty="$(env FWLIVE_OPKG_KEY_URL='https://example.com/k' printf '%s' "${FWLIVE_OPKG_KEY_URL:-}")"
[[ -z "$empty" ]] || fail "env without sh -c must expand before set (got $empty)"
got="$(env FWLIVE_OPKG_KEY_URL='https://example.com/k' sh -c 'printf %s "$FWLIVE_OPKG_KEY_URL"')"
[[ "$got" == 'https://example.com/k' ]] || fail "env sh -c must expand after set (got $got)"

# --stop with no pidfile is success (nothing to kill).
out="$(OWRT_QEMU_PIDFILE="$TMP/missing.pid" "$X86" --stop 2>&1)"
[[ "$out" == *"No x86 QEMU pid file"* ]] || fail "x86 --stop without pidfile: $out"
[[ "$out" == *"--force"* ]] || fail "x86 --stop must mention --force"

out="$(OWRT_QEMU_PIDFILE="$TMP/missing.pid" "$X86" --force --stop 2>&1)"
[[ "$out" == *"No x86 QEMU"* ]] || fail "x86 --force --stop must take the stop path: $out"

set +e
out="$(OWRT_QEMU_PIDFILE="$TMP/missing.pid" "$X86" --stop --force extra 2>&1)"
extra_rc=$?
set -e
[[ "$extra_rc" -ne 0 ]] || fail "--stop --force extra must fail"
[[ "$out" == *"unknown arg: extra"* ]] || fail "extra arg must be named ($out)"

set +e
out="$(OWRT_QEMU_PIDFILE="$TMP/missing.pid" "$X86" --force 2>&1)"
force_only_rc=$?
set -e
[[ "$force_only_rc" -ne 0 ]] || fail "--force without --stop must fail"
[[ "$out" == *"--force requires --stop"* ]] || fail "--force alone must require --stop ($out)"

# Live pidfile whose cmdline matches the pattern: stop kills that PID only.
sleep 60 &
live_pid=$!
printf '%s\n' "$live_pid" >"$TMP/live.pid"
if ! kill -0 "$live_pid" 2>/dev/null; then
	fail "sleep fixture died before stop"
fi
out="$(qemu_lab_stop_guest "$TMP/live.pid" 'sleep' x86 0 2>&1)" || fail "matching pidfile stop failed: $out"
[[ "$out" == *"Stopped x86 QEMU pid ${live_pid}"* ]] || fail "pidfile stop: $out"
if kill -0 "$live_pid" 2>/dev/null; then
	kill "$live_pid" 2>/dev/null || true
	fail "pidfile stop left pid $live_pid running"
fi
[[ ! -f "$TMP/live.pid" ]] || fail "pidfile must be removed after stop"

# A live non-QEMU pidfile fails closed without --force and preserves the handle.
sleep 60 &
wrong_pid=$!
printf '%s\n' "$wrong_pid" >"$TMP/wrong.pid"
set +e
out="$(OWRT_QEMU_PIDFILE="$TMP/wrong.pid" "$X86" --stop 2>&1)"
wrong_rc=$?
set -e
[[ "$wrong_rc" -ne 0 ]] || {
	kill "$wrong_pid" 2>/dev/null || true
	fail "non-QEMU pidfile --stop must refuse without --force (got $wrong_rc: $out)"
}
[[ "$out" == *"is not x86 QEMU"* ]] || {
	kill "$wrong_pid" 2>/dev/null || true
	fail "non-QEMU pidfile must name the mismatch ($out)"
}
if ! kill -0 "$wrong_pid" 2>/dev/null; then
	fail "non-QEMU pidfile stop must not kill the process"
fi

# A live PID that this user cannot signal must not be cleared as stale.
(
	kill() {
		if [[ "$1" == "-0" ]]; then
			return 1
		fi
		return 0
	}
	printf '%s\n' "$BASHPID" >"$TMP/permission.pid"
	set +e
	qemu_lab_kill_pidfile "$TMP/permission.pid" x86 'qemu-system-x86_64' >"$TMP/permission.log" 2>&1
	rc=$?
	set -e
	[[ "$rc" -eq 2 ]] || fail "a live unsignalable PID must return 2 (got $rc)"
	grep -Fq "cannot be verified as absent" "$TMP/permission.log" \
		|| fail "unsignalable PID must be identified as live ($(cat "$TMP/permission.log"))"
	[[ -f "$TMP/permission.pid" ]] || fail "unsignalable PID must not clear its pidfile"
)

# If procfs can hide process entries, an absent directory does not prove ESRCH.
(
	kill() {
		if [[ "$1" == "-0" ]]; then
			return 1
		fi
		return 0
	}
	qemu_lab_proc_hides_processes() {
		return 0
	}
	printf '%s\n' 999999 >"$TMP/hidden-proc.pid"
	set +e
	qemu_lab_kill_pidfile "$TMP/hidden-proc.pid" x86 'qemu-system-x86_64' >"$TMP/hidden-proc.log" 2>&1
	rc=$?
	set -e
	[[ "$rc" -eq 2 ]] || fail "a potentially hidden PID must return 2 (got $rc)"
	grep -Fq "cannot be verified as absent" "$TMP/hidden-proc.log" \
		|| fail "potentially hidden PID must not be classified as stale ($(cat "$TMP/hidden-proc.log"))"
	[[ -f "$TMP/hidden-proc.pid" ]] || fail "potentially hidden PID must not clear its pidfile"
)

# An unreadable cmdline for an accessible live PID is an error, not a stale PID.
(
	tr() {
		if [[ "${1:-}" == "-d" ]]; then
			command tr "$@"
		fi
	}
	printf '%s\n' "$BASHPID" >"$TMP/unreadable.pid"
	set +e
	qemu_lab_kill_pidfile "$TMP/unreadable.pid" x86 'qemu-system-x86_64' >"$TMP/unreadable.log" 2>&1
	rc=$?
	set -e
	[[ "$rc" -eq 2 ]] || fail "an unreadable live PID cmdline must return 2 (got $rc)"
	grep -Fq "cannot read cmdline" "$TMP/unreadable.log" \
		|| fail "unreadable live PID cmdline must be reported ($(cat "$TMP/unreadable.log"))"
	[[ -f "$TMP/unreadable.pid" ]] || fail "unreadable live PID must not clear its pidfile"
)

# --force ignores the live mismatched PID but reaches the matching guest by pattern.
bash -c 'exec -a fwlive-qemu-pattern-target sleep 60' pattern_target &
pattern_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	cmdline="$(tr '\0' ' ' <"/proc/${pattern_pid}/cmdline" 2>/dev/null || true)"
	[[ "$cmdline" == *"fwlive-qemu-pattern-target"* ]] && break
	sleep 0.1
done
[[ "$cmdline" == *"fwlive-qemu-pattern-target"* ]] || {
	kill "$wrong_pid" "$pattern_pid" 2>/dev/null || true
	fail "pattern fixture did not adopt its QEMU-style argv0 (got: $cmdline)"
}
out="$(qemu_lab_stop_guest "$TMP/wrong.pid" 'fwlive-qemu-pattern-target' x86 1 2>&1)" || {
	kill "$wrong_pid" "$pattern_pid" 2>/dev/null || true
	fail "--force must use the pattern fallback for a live mismatched pidfile: $out"
}
[[ "$out" == *"via pattern (--force)"* ]] || {
	kill "$wrong_pid" "$pattern_pid" 2>/dev/null || true
	fail "--force fallback must identify the pattern stop ($out)"
}
[[ ! -f "$TMP/wrong.pid" ]] || {
	kill "$wrong_pid" 2>/dev/null || true
	kill "$pattern_pid" 2>/dev/null || true
	fail "successful --force pattern fallback must clear the mismatched pidfile"
}
if kill -0 "$pattern_pid" 2>/dev/null; then
	kill "$wrong_pid" "$pattern_pid" 2>/dev/null || true
	fail "--force pattern fallback left the matching guest alive"
fi
if ! kill -0 "$wrong_pid" 2>/dev/null; then
	fail "--force pattern fallback must not kill the unrelated pidfile process"
fi
kill "$wrong_pid" 2>/dev/null || true
wait "$wrong_pid" 2>/dev/null || true
wait "$pattern_pid" 2>/dev/null || true

# SIGTERM-ignored guest: kill_pidfile must return 2 so --stop is nonzero.
bash -c 'trap "" TERM; echo ready >"$1"; exec -a fwlive-qemu-stubborn sleep 60' \
	stubborn "$TMP/stubborn.ready" &
stubborn_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[[ -f "$TMP/stubborn.ready" ]] && break
	sleep 0.1
done
[[ -f "$TMP/stubborn.ready" ]] || {
	kill -KILL "$stubborn_pid" 2>/dev/null || true
	fail "SIGTERM-ignored fixture did not become ready"
}
printf '%s\n' "$stubborn_pid" >"$TMP/stubborn.pid"
set +e
qemu_lab_kill_pidfile "$TMP/stubborn.pid" stubborn 'fwlive-qemu-stubborn' >"$TMP/stubborn.log" 2>&1
stubborn_rc=$?
set -e
[[ "$stubborn_rc" -eq 2 ]] || {
	kill -KILL "$stubborn_pid" 2>/dev/null || true
	fail "SIGTERM-ignored pid must return 2 (got $stubborn_rc: $(cat "$TMP/stubborn.log"))"
}
grep -Fq "still running after SIGTERM" "$TMP/stubborn.log" \
	|| fail "non-forced stop must describe its final signal ($(cat "$TMP/stubborn.log"))"
if ! kill -0 "$stubborn_pid" 2>/dev/null; then
	fail "SIGTERM-ignored fixture exited unexpectedly"
fi
kill -KILL "$stubborn_pid" 2>/dev/null || true
wait "$stubborn_pid" 2>/dev/null || true
rm -f "$TMP/stubborn.pid"

# Start path: live pidfile whose cmdline is not this guest is stale, not a wedge.
sleep 60 &
prep_pid=$!
printf '%s\n' "$prep_pid" >"$TMP/prep.pid"
out="$(qemu_lab_prepare_pidfile "$TMP/prep.pid" 'qemu-system-x86_64.*openwrt-x86-64' x86 2>&1)" \
	|| {
		kill "$prep_pid" 2>/dev/null || true
		fail "mismatched live pidfile must not block start: $out"
	}
[[ "$out" == *"rm -f ${TMP}/prep.pid"* ]] || {
	kill "$prep_pid" 2>/dev/null || true
	fail "prepare_pidfile mismatch must name rm -f ($out)"
}
[[ ! -f "$TMP/prep.pid" ]] || {
	kill "$prep_pid" 2>/dev/null || true
	fail "prepare_pidfile must remove a mismatched pidfile"
}
if ! kill -0 "$prep_pid" 2>/dev/null; then
	fail "prepare_pidfile must not kill the mismatched pid"
fi
kill "$prep_pid" 2>/dev/null || true
wait "$prep_pid" 2>/dev/null || true

# --force must SIGKILL a SIGTERM-ignoring matching guest and only then print Stopped.
bash -c 'trap "" TERM; echo ready >"$1"; exec -a fwlive-qemu-force-stubborn sleep 60' \
	force_stubborn "$TMP/force-stubborn.ready" &
force_stubborn_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[[ -f "$TMP/force-stubborn.ready" ]] && break
	sleep 0.1
done
[[ -f "$TMP/force-stubborn.ready" ]] || {
	kill -KILL "$force_stubborn_pid" 2>/dev/null || true
	fail "force SIGTERM-ignored fixture did not become ready"
}
printf '%s\n' "$force_stubborn_pid" >"$TMP/force-stubborn.pid"
set +e
qemu_lab_stop_guest "$TMP/force-stubborn.pid" 'fwlive-qemu-force-stubborn' stubborn 1 \
	>"$TMP/force-stubborn.log" 2>&1
force_stubborn_rc=$?
set -e
[[ "$force_stubborn_rc" -eq 0 ]] || {
	kill -KILL "$force_stubborn_pid" 2>/dev/null || true
	fail "--force must stop a SIGTERM-ignored guest (got $force_stubborn_rc: $(cat "$TMP/force-stubborn.log"))"
}
if kill -0 "$force_stubborn_pid" 2>/dev/null; then
	kill -KILL "$force_stubborn_pid" 2>/dev/null || true
	fail "--force left a SIGTERM-ignored guest running"
fi
grep -Fq "Stopped stubborn QEMU pid ${force_stubborn_pid}" "$TMP/force-stubborn.log" \
	|| fail "--force must confirm the pid stopped ($(cat "$TMP/force-stubborn.log"))"
[[ ! -f "$TMP/force-stubborn.pid" ]] || fail "--force must remove the pidfile"
wait "$force_stubborn_pid" 2>/dev/null || true

# If force still cannot reap a PID after SIGKILL, the diagnostic must name SIGKILL.
(
	kill() {
		return 0
	}
	qemu_lab_wait_pid_gone() {
		return 1
	}
	printf '%s\n' "$BASHPID" >"$TMP/sigkill-still.pid"
	set +e
	qemu_lab_kill_pidfile "$TMP/sigkill-still.pid" stubborn bash 1 >"$TMP/sigkill-still.log" 2>&1
	rc=$?
	set -e
	[[ "$rc" -eq 2 ]] || fail "unreaped forced stop must return 2 (got $rc)"
	grep -Fq "still running after SIGKILL" "$TMP/sigkill-still.log" \
		|| fail "forced-stop diagnostic must name SIGKILL ($(cat "$TMP/sigkill-still.log"))"
	if grep -Fq "still running after SIGTERM" "$TMP/sigkill-still.log"; then
		fail "forced-stop diagnostic must not still claim SIGTERM was final"
	fi
)

# Stale pidfile is not treated as a live guest.
printf '%s\n' 999999 >"$TMP/stale.pid"
set +e
out="$(OWRT_QEMU_PIDFILE="$TMP/stale.pid" "$X86" --stop 2>&1)"
stale_rc=$?
set -e
[[ "$stale_rc" -eq 0 ]] || fail "stale pidfile --stop must be success (got $stale_rc: $out)"
[[ "$out" == *"stale x86 pidfile"* ]] || fail "stale pidfile: $out"
[[ "$out" == *"rm -f ${TMP}/stale.pid"* ]] || fail "stale pidfile must name rm -f: $out"
[[ ! -f "$TMP/stale.pid" ]] || fail "stale pidfile must be removed"

# --force pkill of a uniquely named fixture (not a real qemu-system).
bash -c 'exec -a fwlive-qemu-lifecycle-probe sleep 60' &
probe_pid=$!
sleep 0.1
if ! kill -0 "$probe_pid" 2>/dev/null; then
	fail "force-pkill fixture died before stop"
fi
# Helper only: do not --force the real runners (their pattern is qemu-system-*).
if ! qemu_lab_stop_guest "$TMP/no-such.pid" 'fwlive-qemu-lifecycle-probe' probe 1 \
	>"$TMP/force.log"; then
	kill "$probe_pid" 2>/dev/null || true
	fail "force stop helper failed: $(cat "$TMP/force.log")"
fi
grep -Fq 'Stopped probe QEMU via pattern (--force).' "$TMP/force.log" \
	|| fail "force stop must use the pattern path ($(cat "$TMP/force.log"))"
if kill -0 "$probe_pid" 2>/dev/null; then
	kill "$probe_pid" 2>/dev/null || true
	fail "--force pkill left the probe running"
fi

# assert_qemu_up: dead pid fails closed and dumps the console tail.
printf '%s\n' 'console fixture' >"$TMP/console.log"
if OWRT_CONSOLE_LOG="$TMP/console.log" \
	validate_matrix_assert_qemu_up x86 999999 >"$TMP/dead.log" 2>&1; then
	fail "dead pid must fail assert_qemu_up"
fi
grep -Fq 'QEMU process 999999 is not running' "$TMP/dead.log" \
	|| fail "dead pid must be named ($(cat "$TMP/dead.log"))"
grep -Fq 'console fixture' "$TMP/dead.log" \
	|| fail "dead pid must dump the console tail ($(cat "$TMP/dead.log"))"

# Live pid, no listener: fail after a short poll.
if OWRT_CONSOLE_LOG="$TMP/console.log" \
	OPENWRT_SSH_PORT=59999 \
	OWRT_VALIDATE_QEMU_PORT_TRIES=1 \
	validate_matrix_assert_qemu_up x86 "$$" >"$TMP/noport.log" 2>&1; then
	fail "missing listener must fail assert_qemu_up"
fi
grep -Fq 'SSH port 59999 is not listening' "$TMP/noport.log" \
	|| fail "missing listener must be named ($(cat "$TMP/noport.log"))"

# Live pid + listener: pass.
python3 - "$TMP" <<'PY' &
import socket, sys, time
port_path = sys.argv[1] + "/listen.port"
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(1)
with open(port_path, "w", encoding="utf-8") as fh:
	fh.write(str(s.getsockname()[1]))
time.sleep(30)
s.close()
PY
listen_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[[ -s "$TMP/listen.port" ]] && break
	sleep 0.1
done
[[ -s "$TMP/listen.port" ]] || {
	kill "$listen_pid" 2>/dev/null || true
	fail "python listener did not publish a port"
}
listen_port="$(cat "$TMP/listen.port")"
if ! OWRT_CONSOLE_LOG="$TMP/console.log" \
	OPENWRT_SSH_PORT="$listen_port" \
	OWRT_VALIDATE_QEMU_PORT_TRIES=5 \
	validate_matrix_assert_qemu_up x86 "$listen_pid"; then
	kill "$listen_pid" 2>/dev/null || true
	fail "listening port must pass assert_qemu_up"
fi
kill "$listen_pid" 2>/dev/null || true
wait "$listen_pid" 2>/dev/null || true

# First failing stop must keep the nonzero status after a later success.
validate_matrix_stop_one() {
	printf '%s\n' "$1" >>"$TMP/stopped"
	[[ "$1" != x86 ]]
}
set +e
validate_matrix_stop_qemu
agg_rc=$?
set -e
[[ "$agg_rc" -ne 0 ]] || fail "stop_qemu must stay nonzero when x86 fails"
grep -Fxq x86 "$TMP/stopped" || fail "stop_qemu must still attempt x86"
grep -Fxq armsr "$TMP/stopped" || fail "stop_qemu must still attempt armsr after x86 fails"

echo "qemu lifecycle (#815 #805 #808 #924 #888) passed"

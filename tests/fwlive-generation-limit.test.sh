#!/usr/bin/env bash
# Exercise the shipped generation counter at its configured signed-32-bit
# boundary while holding the real logging lock. This is a host-shell test: it
# probes and reports the host arithmetic width, and does not claim to emulate
# a 32-bit OpenWrt runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGGING_SH="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die() { echo "fwlive-generation-limit test FAIL: $*" >&2; exit 1; }
ok() { echo "fwlive-generation-limit test OK: $*"; }

[ -r "$LOGGING_SH" ] || die "shipped logging helper is missing"
command -v flock >/dev/null 2>&1 || die "flock is required to exercise the real lock"
command -v python3 >/dev/null 2>&1 || die "python3 is required for the guard mutation control"

cat > "$WORK/check-boundary.sh" <<'EOF'
#!/bin/sh
helper="$1"
generation_file="$2"
lock_file="$3"
FWLIVE_WAN_LOG_GENERATION_FILE="$generation_file"
FWLIVE_WAN_LOG_LOCK_FILE="$lock_file"
export FWLIVE_WAN_LOG_GENERATION_FILE FWLIVE_WAN_LOG_LOCK_FILE
. "$helper" || exit 10

acquire_wan_log_lock || exit 11
locked=1
cleanup() {
	if [ "$locked" = 1 ]; then
		release_wan_log_lock
		locked=0
	fi
}
trap cleanup EXIT HUP INT TERM

first="$(wan_log_generation_bump)" || exit 12
[ "$first" = 2147483646 ] || exit 13
[ "$(cat "$generation_file")" = 2147483646 ] || exit 14

if wan_log_generation_bump >/dev/null 2>&1; then
	# Exit 42 is an intentional marker: the mutated helper admitted a bump
	# beyond the configured boundary, proving the host fixture catches it.
	[ "$(cat "$generation_file")" = 2147483647 ] || exit 15
	printf '%s\n' BOUNDARY_GUARD_MUTATION_ACCEPTED >&2
	exit 42
fi

[ "$(cat "$generation_file")" = 2147483646 ] || exit 16
expected="$generation_file.expected"
printf '2147483646\n' > "$expected" || exit 17
cmp -s "$expected" "$generation_file" || exit 18
rm -f "$expected"

leftovers="$(find "$(dirname "$generation_file")" -maxdepth 1 -type f \
	-name "$(basename "$generation_file").*" -print 2>/dev/null)" || exit 19
[ -z "$leftovers" ] || exit 20
cleanup
trap - EXIT HUP INT TERM
exit 0
EOF
chmod +x "$WORK/check-boundary.sh"

# Weaken just the production guard in a disposable copy. The test must observe
# the next increment being admitted and classify that as the expected mutant
# rejection; the shipped helper is never modified.
MUTANT_SH="$WORK/fwlive-logging-mutant.sh"
python3 - "$LOGGING_SH" "$MUTANT_SH" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
guard = '[ "$_generation_value" -lt 2147483646 ] || return 1'
replacement = '[ "$_generation_value" -lt 2147483647 ] || return 1'
count = source.count(guard)
if count != 1:
    raise SystemExit(f"expected exactly one generation limit guard, found {count}")
pathlib.Path(sys.argv[2]).write_text(source.replace(guard, replacement, 1))
PY

run_shell() {
	name="$1"
	shift
	command=("$@")
	# Keep arithmetic quoted so the selected test shell evaluates its own width.
	# shellcheck disable=SC2016
	probe="$("${command[@]}" -c 'printf "%s" "$((2147483647 + 1))"' 2>/dev/null || printf 'unavailable')"
	echo "fwlive-generation-limit: $name host arithmetic probe (2147483647 + 1): $probe"

	for helper_kind in shipped mutant; do
		dir="$WORK/$name-$helper_kind"
		mkdir -p "$dir/runtime"
		chmod 0700 "$dir/runtime"
		generation_file="$dir/runtime/wan-log-generation"
		lock_file="$dir/fwlive-logging.lock"
		printf '2147483645\n' > "$generation_file"
		helper="$LOGGING_SH"
		[ "$helper_kind" != mutant ] || helper="$MUTANT_SH"

		set +e
		"${command[@]}" "$WORK/check-boundary.sh" "$helper" \
			"$generation_file" "$lock_file" \
			>"$dir/stdout" 2>"$dir/stderr"
		rc=$?
		set -e
		if [ "$helper_kind" = shipped ]; then
			[ "$rc" -eq 0 ] || die "$name shipped helper boundary check failed (rc=$rc): $(cat "$dir/stderr")"
			[ "$(cat "$generation_file")" = 2147483646 ] \
				|| die "$name shipped helper changed the generation incorrectly"
			ok "$name increments 2147483645 to 2147483646, then refuses without truncation or temp files"
		else
			[ "$rc" -eq 42 ] \
				|| die "$name guard mutation was not rejected as expected (rc=$rc): $(cat "$dir/stderr")"
			grep -qx 'BOUNDARY_GUARD_MUTATION_ACCEPTED' "$dir/stderr" \
				|| die "$name mutation rejection marker missing"
			[ "$(cat "$generation_file")" = 2147483647 ] \
				|| die "$name weakened guard did not advance past the configured limit"
			ok "$name rejects the weakened-limit mutation"
		fi
	done
}

if command -v dash >/dev/null 2>&1; then
	run_shell dash dash
else
	die "dash is required for the POSIX-shell boundary check"
fi

if command -v busybox >/dev/null 2>&1 && busybox sh -c ':' >/dev/null 2>&1; then
	run_shell 'BusyBox ash' busybox sh
else
	echo "fwlive-generation-limit: SKIP BusyBox ash (busybox unavailable)"
fi

ok "host arithmetic probes are informational; this test does not claim a 32-bit runtime"

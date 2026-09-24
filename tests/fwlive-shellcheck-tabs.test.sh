#!/usr/bin/env bash
# Fixture pins for the libexec tab-indent gate (#580).
# Copy the real wrapper into a mini-repo so ROOT path math matches production.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/scripts/fwlive-shellcheck.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "Install shellcheck (e.g. apt install shellcheck) to run this test." >&2
	exit 1
fi

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LIBEXEC_REL="openwrt-feed/luci-app-fwlive/root/usr/libexec"

make_tree() {
	local dest="$1"
	rm -rf "$dest"
	mkdir -p "$dest/scripts" "$dest/$LIBEXEC_REL/rpcd"
	cp "$WRAPPER" "$dest/scripts/fwlive-shellcheck.sh"
	# Empty baseline: fixtures are ShellCheck-clean POSIX sh (no --exclude).
	: >"$dest/scripts/shellcheck-baseline.txt"
}

# Valid POSIX sh so a ShellCheck-only failure cannot satisfy a negative pin.
write_sh() {
	local dest="$1" prefix="$2"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%secho ok\n' "$prefix"
	} >"$dest"
}

run_wrapper() {
	local dest="$1"
	bash "$dest/scripts/fwlive-shellcheck.sh" >"$dest/stdout" 2>"$dest/stderr"
}

assert_indent_fail() {
	local dest="$1" why="$2" path_needle="$3"
	if run_wrapper "$dest"; then
		bad "$why: wrapper exited 0"
		return
	fi
	if ! grep -q 'FAIL: space indent:' "$dest/stderr"; then
		bad "$why: missing indent diagnostic"
		cat "$dest/stderr" >&2
		return
	fi
	if ! grep -F "FAIL: space indent:" "$dest/stderr" | grep -Fq "$path_needle"; then
		bad "$why: indent diagnostic did not name $path_needle"
		cat "$dest/stderr" >&2
		return
	fi
	ok "$why"
}

assert_pass() {
	local dest="$1" why="$2"
	if ! run_wrapper "$dest"; then
		bad "$why: wrapper failed"
		cat "$dest/stderr" >&2
		return
	fi
	if grep -q 'FAIL: space indent:' "$dest/stderr"; then
		bad "$why: unexpected indent diagnostic"
		cat "$dest/stderr" >&2
		return
	fi
	ok "$why"
}

# Space-first line fails in a *.sh file.
tree="$TMP/space-sh"
make_tree "$tree"
write_sh "$tree/$LIBEXEC_REL/probe.sh" '    '
write_sh "$tree/$LIBEXEC_REL/rpcd/fwlive" $'\t'
assert_indent_fail "$tree" "space-first .sh fails" "probe.sh"

# Space-first line fails in nested extensionless rpcd/fwlive.
tree="$TMP/space-rpcd"
make_tree "$tree"
write_sh "$tree/$LIBEXEC_REL/ok.sh" $'\t'
write_sh "$tree/$LIBEXEC_REL/rpcd/fwlive" '    '
assert_indent_fail "$tree" "space-first rpcd/fwlive fails" "rpcd/fwlive"

# Tab followed by alignment spaces passes (and ShellCheck still runs).
tree="$TMP/tab-align"
make_tree "$tree"
write_sh "$tree/$LIBEXEC_REL/ok.sh" $'\t    '
write_sh "$tree/$LIBEXEC_REL/rpcd/fwlive" $'\t    '
assert_pass "$tree" "tab then alignment spaces passes"
if grep -q 'shellcheck OK' "$tree/stderr"; then
	ok "pass path still runs ShellCheck"
else
	bad "pass path did not run ShellCheck"
	cat "$tree/stderr" >&2
fi

# Space-indented unrelated extension is ignored.
tree="$TMP/ignore-awk"
make_tree "$tree"
write_sh "$tree/$LIBEXEC_REL/ok.sh" $'\t'
write_sh "$tree/$LIBEXEC_REL/rpcd/fwlive" $'\t'
printf '    { print }\n' >"$tree/$LIBEXEC_REL/fwlive-is-firewall-event.awk"
assert_pass "$tree" "space-indented .awk is ignored"

if [[ "$fail" -ne 0 ]]; then
	exit 1
fi
echo "ok: tab indent fixture pins"

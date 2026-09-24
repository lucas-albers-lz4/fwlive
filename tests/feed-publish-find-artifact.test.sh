#!/usr/bin/env bash
# Guard: reused out/ dirs accumulate versioned packages; pick expected
# PKG_VERSION, then newest mtime among matches (#495, #592).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"

assert_eq() {
	local got="$1" want="$2" msg="$3"
	if [[ "$got" != "$want" ]]; then
		echo "FAIL: $msg (got '$got', want '$want')" >&2
		exit 1
	fi
}

assert_fails() {
	local msg="$1"
	shift
	local err
	err="$(mktemp)"
	if "$@" > /dev/null 2>"$err"; then
		echo "FAIL: $msg (expected non-zero)" >&2
		rm -f "$err"
		exit 1
	fi
	printf '%s' "$err"
}

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export FEED_PUBLISH_ROOT="$fixture"

dir="${fixture}/out/x86_64/23.05.5/fwlive"
mkdir -p "$dir"
stale="${dir}/luci-app-fwlive_0.1.44_all.ipk"
fresh="${dir}/luci-app-fwlive_0.1.45_all.ipk"
echo stale > "$stale"
echo fresh > "$fresh"
# Alphabetical ls -1 | head -1 would pick 0.1.44. Stamp mtimes so 0.1.45 is newer.
touch -t 202601010000 "$stale"
touch -t 202601020000 "$fresh"

got="$(feed_publish_find_artifact 23.05.5 0.1.45)"
assert_eq "$got" "$fresh" "newer mtime wins over alphabetical first among version matches"

# Discriminating invert: 0.1.45 is older; later-named 0.1.46 is newest.
# Alphabetical ls -1 would pick 0.1.45; ls -1t must pick 0.1.46 when that
# version is requested.
rm -f "$stale"
older="${dir}/luci-app-fwlive_0.1.45_all.ipk"
newest="${dir}/luci-app-fwlive_0.1.46_all.ipk"
echo older > "$older"
echo newest > "$newest"
touch -t 202601040000 "$older"
touch -t 202601050000 "$newest"

alpha="$(ls -1 "$older" "$newest" | head -1)"
assert_eq "$alpha" "$older" "fixture: alphabetical ls -1 picks older-named 0.1.45"
got="$(feed_publish_find_artifact 23.05.5 0.1.46)"
assert_eq "$got" "$newest" "ls -1t picks later-named 0.1.46 that alphabetical ls -1 would not"

# Mtime applies only among version-matched candidates: a newer 0.1.46 must
# not satisfy a request for 0.1.45.
got="$(feed_publish_find_artifact 23.05.5 0.1.45)"
assert_eq "$got" "$older" "newer different version does not win over the requested PKG_VERSION"

# Equal mtimes: GNU ls -1t falls back to lexicographic name order (0.1.44
# before 0.1.45). Version assertion must still select the requested file.
rm -f "$older" "$newest"
eq_old="${dir}/luci-app-fwlive_0.1.44_all.ipk"
eq_new="${dir}/luci-app-fwlive_0.1.45_all.ipk"
echo eq-old > "$eq_old"
echo eq-new > "$eq_new"
touch -t 202601060000 "$eq_old" "$eq_new"
lex="$(ls -1t "$eq_old" "$eq_new" | head -1)"
assert_eq "$lex" "$eq_old" "fixture: equal-mtime ls -1t picks lexicographic 0.1.44"
got="$(feed_publish_find_artifact 23.05.5 0.1.45)"
assert_eq "$got" "$eq_new" "equal mtime still selects the expected PKG_VERSION"

# Two files of the requested version: newest mtime among those matches.
rm -f "$eq_old" "$eq_new"
apk_old="${dir}/luci-app-fwlive-0.1.45-r1.apk"
apk_new="${dir}/luci-app-fwlive-0.1.45-r2.apk"
echo apk-old > "$apk_old"
echo apk-new > "$apk_new"
touch -t 202601070000 "$apk_old"
touch -t 202601080000 "$apk_new"
got="$(feed_publish_find_artifact 23.05.5 0.1.45)"
assert_eq "$got" "$apk_new" "mtime ordering still applies among version-matched candidates"

# OpenWrt IPK: luci-app-fwlive_${PKG_VERSION}-${PKG_RELEASE}_all.ipk
rm -f "$apk_old" "$apk_new"
ipk_rel="${dir}/luci-app-fwlive_0.1.45-1_all.ipk"
echo ipk-rel > "$ipk_rel"
got="$(feed_publish_find_artifact 23.05.5 0.1.45)"
assert_eq "$got" "$ipk_rel" "IPK PKG_RELEASE suffix -1 must match PKG_VERSION"
rm -f "$ipk_rel"

# No matching artifact → fail closed with a clear error.
err="$(assert_fails "missing PKG_VERSION fails closed" feed_publish_find_artifact 23.05.5 0.1.99)"
grep -q 'PKG_VERSION 0.1.99' "$err" || {
	echo "FAIL: mismatch error must name the expected PKG_VERSION" >&2
	cat "$err" >&2
	rm -f "$err"
	exit 1
}
rm -f "$err"

err="$(assert_fails "empty expected version fails closed" feed_publish_find_artifact 23.05.5 "")"
grep -q 'expected package version is required' "$err" || {
	echo "FAIL: empty version must report that the argument is required" >&2
	cat "$err" >&2
	rm -f "$err"
	exit 1
}
rm -f "$err"

echo "feed-publish find-artifact version+mtime tests passed"

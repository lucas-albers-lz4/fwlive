#!/usr/bin/env bash
# Guard: reused out/ dirs accumulate versioned packages; pick newest mtime, not ls name order (#495).
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

got="$(feed_publish_find_artifact 23.05.5)"
assert_eq "$got" "$fresh" "newer mtime wins over alphabetical first"

# Discriminating invert: 0.1.45 is older; later-named 0.1.46 is newest.
# Alphabetical ls -1 would pick 0.1.45; ls -1t must pick 0.1.46.
rm -f "$stale"
older="${dir}/luci-app-fwlive_0.1.45_all.ipk"
newest="${dir}/luci-app-fwlive_0.1.46_all.ipk"
echo older > "$older"
echo newest > "$newest"
touch -t 202601040000 "$older"
touch -t 202601050000 "$newest"

alpha="$(ls -1 "$older" "$newest" | head -1)"
assert_eq "$alpha" "$older" "fixture: alphabetical ls -1 picks older-named 0.1.45"
got="$(feed_publish_find_artifact 23.05.5)"
assert_eq "$got" "$newest" "ls -1t picks later-named 0.1.46 that alphabetical ls -1 would not"

echo "feed-publish find-artifact newest-mtime tests passed"

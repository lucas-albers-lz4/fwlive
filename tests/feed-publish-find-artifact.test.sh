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

# Invert: newest mtime still wins when the filename sorts later.
touch -t 202601030000 "$stale"
got="$(feed_publish_find_artifact 23.05.5)"
assert_eq "$got" "$stale" "newest mtime wins even when the filename sorts later"

echo "feed-publish find-artifact newest-mtime tests passed"

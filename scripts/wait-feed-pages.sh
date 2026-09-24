#!/usr/bin/env bash
# Wait until GitHub Pages feed URLs respond (post-deploy).
#
#   ./scripts/wait-feed-pages.sh https://lucas-albers-lz4.github.io/fwlive-packages
#   ./scripts/wait-feed-pages.sh --apk-25.12 BASE_URL   # scheduled 25.12 APK smoke
set -euo pipefail

APK_25_12=0
if [[ "${1:-}" == "--apk-25.12" ]]; then
	APK_25_12=1
	shift
fi

BASE="${1:?usage: wait-feed-pages.sh [--apk-25.12] BASE_URL}"
BASE="${BASE%/}"
MAX_WAIT="${FEED_PAGES_WAIT_SEC:-300}"
INTERVAL="${FEED_PAGES_WAIT_INTERVAL:-10}"

if [[ "$APK_25_12" -eq 1 ]]; then
	urls=(
		"${BASE}/25.12/all/packages.adb"
		"${BASE}/fwlive-feed.rsa.pub"
	)
else
	urls=(
		"${BASE}/24.10/Packages.gz"
		"${BASE}/23.05/Packages.gz"
		"${BASE}/25.12/all/packages.adb"
		"${BASE}/public.key"
		"${BASE}/fwlive-feed.rsa.pub"
	)
fi

deadline=$((SECONDS + MAX_WAIT))
echo "Waiting for feed URLs under ${BASE} (max ${MAX_WAIT}s)..." >&2

while (( SECONDS < deadline )); do
	ok=1
	for u in "${urls[@]}"; do
		if ! curl -fsSIL "$u" >/dev/null 2>&1; then
			ok=0
			echo "  pending: $u" >&2
			break
		fi
	done
	if [[ $ok -eq 1 ]]; then
		echo "All feed URLs reachable." >&2
		exit 0
	fi
	sleep "$INTERVAL"
done

echo "Timeout waiting for GitHub Pages feed at ${BASE}" >&2
exit 1

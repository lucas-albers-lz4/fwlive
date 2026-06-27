#!/usr/bin/env bash
# Wait until GitHub Pages feed URLs respond (post-deploy).
#
#   ./scripts/wait-feed-pages.sh https://lucas-albers-lz4.github.io/fwlive-packages
set -euo pipefail

BASE="${1:?usage: wait-feed-pages.sh BASE_URL}"
BASE="${BASE%/}"
MAX_WAIT="${FEED_PAGES_WAIT_SEC:-300}"
INTERVAL="${FEED_PAGES_WAIT_INTERVAL:-10}"

urls=(
	"${BASE}/21.02/Packages.gz"
	"${BASE}/22.03/Packages.gz"
	"${BASE}/24.10/Packages.gz"
	"${BASE}/23.05/Packages.gz"
	"${BASE}/25.12/all/packages.adb"
	"${BASE}/public.key"
)

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

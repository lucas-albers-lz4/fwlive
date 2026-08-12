#!/usr/bin/env bash
# Grep gate: fetched helpers in scripts/ must be commit-pinned or sha256-verified
# before execution (issue #166). Fail if an unpinned git clone of usign (or a
# curl-to-file without an adjacent verify) reappears.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

# Unpinned usign clone (the S2 defect shape).
if grep -RIn --include='*.sh' -E 'git[[:space:]]+clone.*openwrt/usign' \
	"$ROOT/scripts" 2>/dev/null \
	| grep -v 'USIGN_PIN_SHA\|fetch.*USIGN_PIN\|pinned usign' >/dev/null; then
	echo "FAIL: unpinned openwrt/usign git clone in scripts/" >&2
	grep -RIn --include='*.sh' -E 'git[[:space:]]+clone.*openwrt/usign' "$ROOT/scripts" >&2 || true
	fail=1
else
	echo "ok: no unpinned openwrt/usign clone"
fi

# feed_publish_ensure_usign must reference the pin.
if grep -q "USIGN_PIN_SHA=" "$ROOT/scripts/lib/feed-publish.sh" \
	&& grep -q 'fetch.*USIGN_PIN_SHA\|origin "\${USIGN_PIN_SHA}"\|origin "${USIGN_PIN_SHA}"' \
		"$ROOT/scripts/lib/feed-publish.sh"; then
	echo "ok: feed_publish_ensure_usign is commit-pinned"
else
	echo "FAIL: feed_publish_ensure_usign missing USIGN_PIN_SHA fetch" >&2
	fail=1
fi

# get-sdk.sh must verify sha256 before extract.
if grep -q 'verify_downloaded_sha256' "$ROOT/scripts/get-sdk.sh" \
	&& grep -q 'sha256sums' "$ROOT/scripts/get-sdk.sh"; then
	echo "ok: get-sdk.sh verifies sha256sums"
else
	echo "FAIL: get-sdk.sh missing sha256 verification" >&2
	fail=1
fi

[ "$fail" = "0" ] || exit 1
echo "fetch-pin gate: ok"

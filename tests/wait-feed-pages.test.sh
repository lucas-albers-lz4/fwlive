#!/usr/bin/env bash
# Host proof: wait-feed-pages.sh requests fwlive-feed.rsa.pub (#421 slice 1).
# A PATH curl shim records URLs and exits 0 — no network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
url_log="$TMP/urls"
: >"$url_log"

cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
log="${WAIT_FEED_CURL_LOG:?}"
for a in "$@"; do
	case "$a" in
		http://*|https://*) printf '%s\n' "$a" >>"$log" ;;
	esac
done
exit 0
EOF
chmod +x "$TMP/bin/curl"

export WAIT_FEED_CURL_LOG="$url_log"
export PATH="$TMP/bin:$PATH"
if [[ "$(command -v curl)" != "$TMP/bin/curl" ]]; then
	bad "curl on PATH is not the shim ($(command -v curl))"
fi

base='https://example.invalid/fwlive-packages'
set +e
FEED_PAGES_WAIT_SEC=2 FEED_PAGES_WAIT_INTERVAL=1 \
	"$ROOT/scripts/wait-feed-pages.sh" "$base" >"$TMP/out" 2>&1
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
	ok "wait-feed-pages.sh exits 0 with curl shim"
else
	bad "wait-feed-pages.sh rc=$rc ($(cat "$TMP/out"))"
fi

want="${base}/fwlive-feed.rsa.pub"
if grep -qxF "$want" "$url_log"; then
	ok "requests fwlive-feed.rsa.pub"
else
	bad "did not request $want (urls: $(tr '\n' ' ' <"$url_log"))"
fi

if [[ "$fail" -ne 0 ]]; then
	echo "FAIL: wait-feed-pages APK key wait" >&2
	exit 1
fi
echo "ok: wait-feed-pages APK key wait"

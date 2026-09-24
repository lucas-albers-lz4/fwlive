#!/usr/bin/env bash
# Host proof: wait-feed-pages.sh URL lists (#421).
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

run_wait() {
	: >"$url_log"
	set +e
	FEED_PAGES_WAIT_SEC=2 FEED_PAGES_WAIT_INTERVAL=1 \
		"$ROOT/scripts/wait-feed-pages.sh" "$@" >"$TMP/out" 2>&1
	rc=$?
	set -e
}

run_wait "$base"
if [[ "$rc" -eq 0 ]]; then
	ok "default wait-feed-pages.sh exits 0 with curl shim"
else
	bad "default wait-feed-pages.sh rc=$rc ($(cat "$TMP/out"))"
fi

for want in \
	"${base}/24.10/Packages.gz" \
	"${base}/23.05/Packages.gz" \
	"${base}/25.12/all/packages.adb" \
	"${base}/public.key" \
	"${base}/fwlive-feed.rsa.pub"
do
	if grep -qxF "$want" "$url_log"; then
		ok "default requests $want"
	else
		bad "default did not request $want (urls: $(tr '\n' ' ' <"$url_log"))"
	fi
done

run_wait --apk-25.12 "$base"
if [[ "$rc" -eq 0 ]]; then
	ok "--apk-25.12 wait-feed-pages.sh exits 0 with curl shim"
else
	bad "--apk-25.12 wait-feed-pages.sh rc=$rc ($(cat "$TMP/out"))"
fi

for want in \
	"${base}/25.12/all/packages.adb" \
	"${base}/fwlive-feed.rsa.pub"
do
	if grep -qxF "$want" "$url_log"; then
		ok "--apk-25.12 requests $want"
	else
		bad "--apk-25.12 did not request $want (urls: $(tr '\n' ' ' <"$url_log"))"
	fi
done

for skip in \
	"${base}/24.10/Packages.gz" \
	"${base}/23.05/Packages.gz" \
	"${base}/public.key"
do
	if grep -qxF "$skip" "$url_log"; then
		bad "--apk-25.12 requested $skip (urls: $(tr '\n' ' ' <"$url_log"))"
	else
		ok "--apk-25.12 skips $skip"
	fi
done

if [[ "$fail" -ne 0 ]]; then
	echo "FAIL: wait-feed-pages APK key wait" >&2
	exit 1
fi
echo "ok: wait-feed-pages APK key wait"

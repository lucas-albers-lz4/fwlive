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
printf '%s\n' "$*" >>"${WAIT_FEED_CURL_ARGS:?}"
for a in "$@"; do
	case "$a" in
		http://*|https://*)
			printf '%s\n' "$a" >>"$log"
			if [ "$a" = "${WAIT_FEED_FAIL_URL:-}" ]; then
				printf '000'
				exit 1
			fi
			;;
	esac
done
printf '200'
exit 0
EOF
chmod +x "$TMP/bin/curl"

export WAIT_FEED_CURL_LOG="$url_log"
export WAIT_FEED_CURL_ARGS="$TMP/curl.args"
: >"$WAIT_FEED_CURL_ARGS"
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

if ! grep -Fq -- '--connect-timeout 10' "$WAIT_FEED_CURL_ARGS"; then
	bad "curl must set --connect-timeout 10"
else
	ok "curl uses --connect-timeout 10"
fi
if ! grep -Fq -- '--max-time 30' "$WAIT_FEED_CURL_ARGS"; then
	bad "curl must set --max-time 30"
else
	ok "curl uses --max-time 30"
fi

set +e
FEED_PAGES_WAIT_SEC=abc FEED_PAGES_WAIT_INTERVAL=1 \
	"$ROOT/scripts/wait-feed-pages.sh" "$base" >"$TMP/bad-wait.log" 2>&1
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]] && grep -Fq 'invalid FEED_PAGES_WAIT_SEC' "$TMP/bad-wait.log" \
	&& ok "non-numeric FEED_PAGES_WAIT_SEC fails closed" \
	|| bad "non-numeric wait must fail ($(cat "$TMP/bad-wait.log"))"

# All pending URLs in one round — do not break after the first failure (#811).
export WAIT_FEED_FAIL_URL="${base}/24.10/Packages.gz"
: >"$url_log"
set +e
FEED_PAGES_WAIT_SEC=1 FEED_PAGES_WAIT_INTERVAL=1 \
	"$ROOT/scripts/wait-feed-pages.sh" "$base" >"$TMP/pending.log" 2>&1
pend_rc=$?
set -e
[[ "$pend_rc" -ne 0 ]] || bad "a failing URL must time out"
pending_n="$(grep -c '^  pending:' "$TMP/pending.log" || true)"
[[ "$pending_n" -ge 1 ]] || bad "must report pending URLs ($(cat "$TMP/pending.log"))"
# First-fail break would skip later URLs; 23.05 must still be probed.
if grep -qxF "${base}/23.05/Packages.gz" "$url_log"; then
	ok "pending first URL does not skip later URLs"
else
	bad "broke after first pending URL (urls: $(tr '\n' ' ' <"$url_log"))"
fi
unset WAIT_FEED_FAIL_URL

if [[ "$fail" -ne 0 ]]; then
	echo "FAIL: wait-feed-pages APK key wait" >&2
	exit 1
fi
echo "ok: wait-feed-pages APK key wait"

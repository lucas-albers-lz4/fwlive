#!/usr/bin/env bash
# Drive the production external-URL path with a curl shim (#461).
# Reverting scripts/fwlive-linkcheck.sh (or linkcheck_external.py) back to
# treating a retried 404 as a warning must fail this test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake curl: first probe per URL -> 000; second -> code from the URL path.
# https://shim.example/404 -> 404; /000 -> 000; /200 -> 200.
cat >"$TMP/curl" <<'EOF'
#!/bin/sh
url=""
for a in "$@"; do
	case "$a" in
		http://*|https://*) url="$a" ;;
	esac
done
state_dir="${FWLIVE_LINKCHECK_SHIM_STATE:?}"
key=$(printf '%s' "$url" | sed 's/[^A-Za-z0-9._-]/_/g')
count_file="$state_dir/$key"
n=0
if [ -f "$count_file" ]; then
	n=$(cat "$count_file")
fi
n=$((n + 1))
printf '%s\n' "$n" >"$count_file"
if [ "$n" -eq 1 ]; then
	printf '000'
	exit 0
fi
case "$url" in
	*/404) printf '404' ;;
	*/000) printf '000' ;;
	*/200) printf '200' ;;
	*) printf '418' ;;
esac
EOF
chmod +x "$TMP/curl"

run_probe() {
	local urls="$1"
	local out="$2"
	FWLIVE_LINKCHECK_URLS="$urls" \
		FWLIVE_LINKCHECK_CURL="$TMP/curl" \
		FWLIVE_LINKCHECK_SHIM_STATE="$TMP/state" \
		PYTHONPATH="$ROOT/scripts/lib" \
		python3 "$ROOT/scripts/lib/linkcheck_external.py" \
		>"$out" 2>&1
}

rm -rf "$TMP/state"
mkdir -p "$TMP/state"
if run_probe 'https://shim.example/404' "$TMP/out-404"; then
	bad "000 then 404 must fail the production probe"
else
	ok "000 then 404 fails closed"
fi
grep -q 'FAIL: https://shim.example/404 -> 000 then 404' "$TMP/out-404" \
	&& ok "retry evidence in FAIL line" \
	|| bad "FAIL line should record 000 then 404 ($(cat "$TMP/out-404"))"

# Also run through fwlive-linkcheck.sh so reverting only the .sh dispatch fails.
rm -rf "$TMP/state"
mkdir -p "$TMP/state"
set +e
FWLIVE_LINKCHECK_URLS='https://shim.example/404' \
	FWLIVE_LINKCHECK_CURL="$TMP/curl" \
	FWLIVE_LINKCHECK_SHIM_STATE="$TMP/state" \
	"$ROOT/scripts/fwlive-linkcheck.sh" >"$TMP/sh-404" 2>&1
sh_rc=$?
set -e
if [[ "$sh_rc" -ne 0 ]] && grep -q '000 then 404' "$TMP/sh-404"; then
	ok "fwlive-linkcheck.sh 000-then-404 fails with retry evidence"
else
	bad "fwlive-linkcheck.sh must fail 000-then-404 (rc=$sh_rc)"
fi

rm -rf "$TMP/state"
mkdir -p "$TMP/state"
if run_probe 'https://shim.example/000' "$TMP/out-000"; then
	ok "000 then 000 stays a warning (exit 0)"
else
	bad "double-000 must not fail"
fi
grep -q 'WARN: https://shim.example/000 -> 000' "$TMP/out-000" \
	&& ok "double-000 records a warning" \
	|| bad "double-000 should warn ($(cat "$TMP/out-000"))"

rm -rf "$TMP/state"
mkdir -p "$TMP/state"
if run_probe 'https://shim.example/200' "$TMP/out-200"; then
	ok "000 then 200 is ok"
else
	bad "000 then 200 should succeed"
fi
grep -q 'failed: 0' "$TMP/out-200" \
	&& ok "000 then 200 has zero failures" \
	|| bad "000 then 200 should have failed: 0"

if [[ "$fail" -ne 0 ]]; then
	echo "FAIL: linkcheck external retry harness" >&2
	exit 1
fi
echo "ok: linkcheck external retry harness"

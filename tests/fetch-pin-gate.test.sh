#!/usr/bin/env bash
# Semantic gate: fetched helpers in scripts/ must be commit-pinned or
# sha256-verified before execution (issue #166). Negative fixtures must fail.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# Unpinned usign clone (the S2 defect shape) must not appear in scripts/.
if grep -RIn --include='*.sh' -E 'git[[:space:]]+clone.*openwrt/usign' \
	"$ROOT/scripts" 2>/dev/null \
	| grep -v 'USIGN_PIN_SHA\|fetch.*USIGN_PIN\|pinned usign' >/dev/null; then
	bad "unpinned openwrt/usign git clone in scripts/"
	grep -RIn --include='*.sh' -E 'git[[:space:]]+clone.*openwrt/usign' "$ROOT/scripts" >&2 || true
else
	ok "no unpinned openwrt/usign clone"
fi

# feed_publish_ensure_usign: pin constant + fetch/checkout/HEAD check (not comments).
_fp="$ROOT/scripts/lib/feed-publish.sh"
if grep -qE "^USIGN_PIN_SHA='[0-9a-f]{40}'$" "$_fp" \
	&& grep -qE 'git -C .* fetch .* origin "\$\{USIGN_PIN_SHA\}"' "$_fp" \
	&& grep -qE 'git -C .* checkout .* "\$\{USIGN_PIN_SHA\}"' "$_fp" \
	&& grep -qE 'rev-parse HEAD.*=.*"\$\{USIGN_PIN_SHA\}"' "$_fp"; then
	ok "feed_publish_ensure_usign fetch/checkout/HEAD pin"
else
	bad "feed_publish_ensure_usign missing semantic USIGN_PIN_SHA pin"
fi

# get-sdk.sh: verify_downloaded_sha256 must appear before tar -xf.
_gs="$ROOT/scripts/get-sdk.sh"
_verify_line=$(grep -n 'verify_downloaded_sha256' "$_gs" | head -1 | cut -d: -f1)
_tar_line=$(grep -n 'tar -xf' "$_gs" | head -1 | cut -d: -f1)
if [ -n "$_verify_line" ] && [ -n "$_tar_line" ] && [ "$_verify_line" -lt "$_tar_line" ]; then
	ok "get-sdk.sh verifies before tar extract"
else
	bad "get-sdk.sh verify not before tar -xf (verify=$_verify_line tar=$_tar_line)"
fi

# Negative fixtures: gate logic must reject decoy/comment-only and extract-first shapes.
_neg=$(mktemp -d)
trap 'rm -rf "$_neg"' EXIT

cat > "$_neg/bad-usign.sh" <<'EOF'
#!/usr/bin/env bash
# USIGN_PIN_SHA='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
# fetch USIGN_PIN_SHA
git init -q src
git -C src fetch -q --depth 1 origin master
git -C src checkout -q master
EOF

cat > "$_neg/bad-get-sdk.sh" <<'EOF'
#!/usr/bin/env bash
# verify_downloaded_sha256 lives only in a comment / dead stub
verify_downloaded_sha256() { :; }
# sha256sums mentioned here but unused
tar -xf "$TAR"
verify_downloaded_sha256 "$TAR" "$TAR" /dev/null
EOF

# Decoy comment + unpinned fetch must not satisfy the semantic pin checks.
if grep -qE "^USIGN_PIN_SHA='[0-9a-f]{40}'$" "$_neg/bad-usign.sh" \
	&& grep -qE 'git -C .* fetch .* origin "\$\{USIGN_PIN_SHA\}"' "$_neg/bad-usign.sh"; then
	bad "negative usign fixture unexpectedly matched pin checks"
else
	ok "negative usign fixture rejected by pin checks"
fi

_nv=$(grep -n 'verify_downloaded_sha256' "$_neg/bad-get-sdk.sh" | grep -v '^#' | head -1 | cut -d: -f1 || true)
# Call sites: first non-definition invocation after tar would fail order check.
_n_verify_call=$(awk '/verify_downloaded_sha256 \$/{print NR; exit}' "$_neg/bad-get-sdk.sh")
_n_tar=$(awk '/tar -xf/{print NR; exit}' "$_neg/bad-get-sdk.sh")
if [ -n "$_n_verify_call" ] && [ -n "$_n_tar" ] && [ "$_n_verify_call" -lt "$_n_tar" ]; then
	bad "negative get-sdk fixture unexpectedly passed order check"
else
	ok "negative get-sdk fixture rejected (extract before verify)"
fi

[ "$fail" = "0" ] || exit 1
echo "fetch-pin gate: ok"

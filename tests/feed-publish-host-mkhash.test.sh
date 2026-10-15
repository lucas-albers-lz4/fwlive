#!/usr/bin/env bash
# Host proof: feed_publish_stage_opkg_host indexes with a host-executable
# mkhash even when the SDK probe would return /builder/... (#1282).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

host_work="$(mktemp -d)"
trap 'rm -rf "$host_work"' EXIT
host_pkg="${host_work}/pkg"
host_tools="${host_work}/tools"
mkdir -p "$host_pkg" "$host_tools"
: >"${host_pkg}/luci-app-fwlive_0_all.ipk"

# Probe would prefer the SDK container path over a working host mkhash.
feed_publish_probe_mkhash() { printf '%s' '/builder/staging_dir/host/bin/mkhash'; }

cat >"${host_work}/ipkg-make-index-template.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$MKHASH" >"$MKHASH_USED"
"$MKHASH" sha256 . >/dev/null || exit 1
printf 'Package: luci-app-fwlive\nMaintainer: test\nVersion: 0.0.1-1\n'
EOF
chmod +x "${host_work}/ipkg-make-index-template.sh"

feed_publish_ipkg_index_script() {
	local fresh
	fresh="$(mktemp "${host_work}/ipkg-make-index.XXXXXX")" || return 1
	cp "${host_work}/ipkg-make-index-template.sh" "$fresh"
	chmod +x "$fresh"
	printf '%s\n' "$fresh"
}

cat >"${host_tools}/mkhash" <<'EOF'
#!/bin/sh
printf 'host-mkhash %s\n' "$*" >>"$HOST_TOOL_LOG"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'
EOF
cat >"${host_tools}/gzip" <<'EOF'
#!/bin/sh
printf 'gzip\n' >>"$HOST_TOOL_LOG"
exec /usr/bin/gzip "$@"
EOF
cat >"${host_tools}/usign" <<'EOF'
#!/bin/sh
printf 'usign %s\n' "$*" >>"$HOST_TOOL_LOG"
exit 0
EOF
chmod +x "${host_tools}/mkhash" "${host_tools}/gzip" "${host_tools}/usign"

: >"${host_work}/tool-log"
PATH="${host_tools}:${PATH}" HOST_TOOL_LOG="${host_work}/tool-log" \
	MKHASH_USED="${host_work}/mkhash-used" \
	OPKG_FEED_SECRET_KEY=/dev/null \
	feed_publish_stage_opkg_host "$host_pkg" 24.10.8 \
	>"${host_work}/index.out" 2>"${host_work}/index.err" \
	|| fail "host indexer must succeed with host mkhash on PATH: $(tr '\n' ' ' <"${host_work}/index.err")"

used="$(cat "${host_work}/mkhash-used")"
[[ "$used" == "${host_tools}/mkhash" ]] \
	|| fail "index MKHASH must be host mkhash, got ${used}"
[[ "$used" != /builder/* ]] || fail "index MKHASH must not be the SDK container path"
grep -q "^host-mkhash sha256 " "${host_work}/tool-log" \
	|| fail "host mkhash must run during indexing"
grep -q '^gzip$' "${host_work}/tool-log" || fail "positive path must run gzip"
grep -q '^usign ' "${host_work}/tool-log" || fail "positive path must run usign"
[[ -s "${host_pkg}/Packages.gz" ]] || fail "positive path must produce Packages.gz"

# Missing host mkhash must fail closed even when the probe returns /builder.
no_mkhash="${host_work}/no-mkhash"
mkdir -p "$no_mkhash"
for bin in gzip usign mktemp rm cat grep; do
	src="$(command -v "$bin")" || fail "need $bin to build the missing-mkhash PATH"
	cp "$src" "${no_mkhash}/${bin}"
	chmod +x "${no_mkhash}/${bin}"
done
rm -f "${host_pkg}/Packages" "${host_pkg}/Packages.gz" "${host_pkg}/Packages.sig"
: >"${host_work}/tool-log"
if PATH="${no_mkhash}" HOST_TOOL_LOG="${host_work}/tool-log" \
	MKHASH_USED="${host_work}/mkhash-used-missing" \
	OPKG_FEED_SECRET_KEY=/dev/null \
	feed_publish_stage_opkg_host "$host_pkg" 24.10.8 \
	>"${host_work}/missing.out" 2>"${host_work}/missing.err"; then
	fail "host indexer must fail when mkhash is absent from PATH"
fi
grep -q 'host mkhash not found' "${host_work}/missing.err" \
	|| fail "missing host mkhash must be reported: $(tr '\n' ' ' <"${host_work}/missing.err")"
[[ ! -e "${host_pkg}/Packages.gz" ]] || fail "gzip must not run without host mkhash"

echo "feed-publish host mkhash (#1282) passed"

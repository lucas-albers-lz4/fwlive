#!/usr/bin/env bash
# feed_publish_copy_keys requires both public keys; host Packages filtering
# fails closed on grep I/O errors (#803 #821).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# #821: both index paths must fail closed on grep I/O errors.
if grep -nE 'grep -vE.*Maintainer.*\|\| true' "${ROOT}/scripts/lib/feed-publish.sh"; then
	fail "Packages filter still swallows grep status with || true"
fi
grep -cE 'grep -vE .*\^\(Maintainer' "${ROOT}/scripts/lib/feed-publish.sh" | grep -qx 2 \
	|| fail "expected two Packages Maintainer filters"

staging="$(mktemp -d)"
opkg_pub="$(mktemp)"
apk_pub="$(mktemp)"
trap 'rm -rf "$staging" "$opkg_pub" "$apk_pub"' EXIT
printf 'opkg-public\n' >"$opkg_pub"
printf 'apk-public\n' >"$apk_pub"

# #803: missing opkg key fails even when apk is present.
if OPKG_FEED_PUBLIC_KEY="" APK_FEED_PUBLIC_KEY="$apk_pub" \
	feed_publish_copy_keys "$staging" >/dev/null 2>&1; then
	fail "copy_keys must refuse unset OPKG_FEED_PUBLIC_KEY"
fi
if OPKG_FEED_PUBLIC_KEY="/no/such/opkg.key" APK_FEED_PUBLIC_KEY="$apk_pub" \
	feed_publish_copy_keys "$staging" >/dev/null 2>&1; then
	fail "copy_keys must refuse a missing OPKG_FEED_PUBLIC_KEY path"
fi
[[ ! -e "${staging}/public.key" ]] || fail "failed copy must not leave public.key"
[[ ! -e "${staging}/fwlive-feed.rsa.pub" ]] || fail "failed copy must not leave apk pub"

# missing apk key fails even when opkg is present
if OPKG_FEED_PUBLIC_KEY="$opkg_pub" APK_FEED_PUBLIC_KEY="" \
	feed_publish_copy_keys "$staging" >/dev/null 2>&1; then
	fail "copy_keys must refuse unset APK_FEED_PUBLIC_KEY"
fi

OPKG_FEED_PUBLIC_KEY="$opkg_pub" APK_FEED_PUBLIC_KEY="$apk_pub" \
	feed_publish_copy_keys "$staging" || fail "copy_keys with both keys"
[[ -f "${staging}/public.key" ]] || fail "staged public.key"
[[ -f "${staging}/fwlive-feed.rsa.pub" ]] || fail "staged fwlive-feed.rsa.pub"
[[ "$(cat "${staging}/public.key")" == "opkg-public" ]] || fail "public.key contents"
[[ "$(cat "${staging}/fwlive-feed.rsa.pub")" == "apk-public" ]] || fail "apk pub contents"

# Exercise the real host index/signing function. The only substituted seams
# are the pinned index script and external grep/gzip/usign commands, so the
# production filter's stdout and exit status control signing.
host_work="$(mktemp -d)"
trap 'rm -rf "$staging" "$opkg_pub" "$apk_pub" "$host_work"' EXIT
host_pkg="${host_work}/feed"
host_tools="${host_work}/tools"
mkdir -p "$host_pkg" "$host_tools"
cat >"${host_work}/ipkg-make-index-template.sh" <<'EOF'
#!/bin/sh
printf 'Package: luci-app-fwlive\nMaintainer: test\nVersion: 0.0.1-1\n'
EOF
chmod +x "${host_work}/ipkg-make-index-template.sh"

# Avoid fetching the external pinned script; feed_publish_stage_opkg_host still
# invokes the production path and performs its real grep/gzip/sign sequence.
feed_publish_ipkg_index_script() {
	local fresh
	fresh="$(mktemp "${host_work}/ipkg-make-index.XXXXXX")" || return 1
	cp "${host_work}/ipkg-make-index-template.sh" "$fresh"
	chmod +x "$fresh"
	printf '%s\n' "$fresh"
}
feed_publish_probe_mkhash() { :; }

cat >"${host_tools}/grep" <<'EOF'
#!/bin/sh
case " $* " in
    *" -vE "*)
        # Model an I/O failure after grep emitted a partial index.
        printf 'Package: partial-index\n'
        exit 2
        ;;
esac
exec /usr/bin/grep "$@"
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
chmod +x "${host_tools}/grep" "${host_tools}/gzip" "${host_tools}/usign"

# A failed grep may have written bytes to Packages, but must stop before
# compression and signing. Assert those later production stages were skipped.
: >"${host_work}/tool-log"
if PATH="${host_tools}:${PATH}" HOST_TOOL_LOG="${host_work}/tool-log" \
	OPKG_FEED_SECRET_KEY=/dev/null \
	feed_publish_stage_opkg_host "$host_pkg" 24.10.8 \
	>"${host_work}/grep-failure.out" 2>"${host_work}/grep-failure.err"; then
	fail "host Packages filter must return nonzero on grep I/O error"
fi
[[ "$(cat "${host_pkg}/Packages")" == 'Package: partial-index' ]] \
	|| fail "grep fault fixture must leave the diagnostic partial index"
[[ ! -e "${host_pkg}/Packages.gz" ]] || fail "gzip must not run after grep I/O failure"
[[ ! -e "${host_pkg}/Packages.sig" ]] || fail "usign must not run after grep I/O failure"
[[ ! -s "${host_work}/tool-log" ]] || fail "gzip/usign must not run after grep I/O failure"

# Positive control: valid grep output proceeds through gzip and usign.
cat >"${host_tools}/grep" <<'EOF'
#!/bin/sh
exec /usr/bin/grep "$@"
EOF
chmod +x "${host_tools}/grep"
RETURN_LOG="${host_work}/return.log"
export RETURN_LOG
trap 'printf caller-return >>"$RETURN_LOG"' RETURN
expected_return="$(trap -p RETURN)"
PATH="${host_tools}:${PATH}" HOST_TOOL_LOG="${host_work}/tool-log" \
	OPKG_FEED_SECRET_KEY=/dev/null \
	feed_publish_stage_opkg_host "$host_pkg" 24.10.8 \
	>"${host_work}/positive.out" 2>"${host_work}/positive.err" \
	|| fail "host Packages filter positive control"
[[ -s "${host_pkg}/Packages.gz" ]] || fail "positive control must produce compressed index"
[[ -s "${host_work}/tool-log" ]] || fail "positive control must run gzip and usign"
grep -q '^gzip$' "${host_work}/tool-log" || fail "positive control did not run gzip"
grep -q '^usign ' "${host_work}/tool-log" || fail "positive control did not run usign"
[[ "$(trap -p RETURN)" == "$expected_return" ]] || fail "stage_opkg_host must restore caller RETURN trap"
trap - RETURN

echo "feed-publish copy-keys / Packages filter (#803 #821) passed"

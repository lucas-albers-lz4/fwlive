#!/usr/bin/env bash
# Host proof: the published BASE= feed snippet installs opkg and apk (#1235).
# Rewrites /etc and /tmp onto a fake root; wget/opkg/apk are PATH shims. No network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_first_sh_fence() {
	awk '
		/^```sh$/ { n++; next }
		n == 1 && /^```$/ { exit }
		n == 1 { print }
	' "$1"
}

snippet="$(extract_first_sh_fence "$ROOT/README.md")"
[[ -n "$snippet" ]] || {
	echo "FAIL: README.md has no install \`\`\`sh fence" >&2
	exit 1
}
printf '%s\n' "$snippet" | grep -Fq "BASE='https://lucas-albers-lz4.github.io/fwlive-packages'" \
	|| {
		echo "FAIL: README snippet must start from the published feed BASE" >&2
		exit 1
	}
printf '%s\n' "$snippet" | grep -Fq 'exit 1' && printf '%s\n' "$snippet" | grep -Fq 'uses apk' \
	&& {
		echo "FAIL: README snippet must not exit on 25.12 apk" >&2
		exit 1
	}

packages_snip="$(extract_first_sh_fence "$ROOT/packages-repo/README.md")"
install_snip="$(extract_first_sh_fence "$ROOT/docs/user/installation.md")"
if [[ "$snippet" == "$packages_snip" ]]; then
	ok "packages-repo README snippet matches README.md"
else
	bad "packages-repo README snippet drifted from README.md"
fi
if [[ "$snippet" == "$install_snip" ]]; then
	ok "installation.md snippet matches README.md"
else
	bad "installation.md snippet drifted from README.md"
fi

sh -n -c "$snippet" || {
	echo "FAIL: README snippet is not valid POSIX sh" >&2
	exit 1
}

mkdir -p "$TMP/bin"
cat >"$TMP/bin/wget" <<'EOF'
#!/bin/sh
log="${SNIPPET_CMD_LOG:?}"
out=""
url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-O)
			out="$2"
			shift 2
			;;
		*)
			url="$1"
			shift
			;;
	esac
done
printf 'wget -O %s %s\n' "$out" "$url" >>"$log"
if [ -n "${SNIPPET_WGET_FAIL:-}" ]; then
	exit 1
fi
[ -n "$out" ] || exit 1
printf 'key\n' >"$out"
EOF
cat >"$TMP/bin/opkg-key" <<'EOF'
#!/bin/sh
printf 'opkg-key %s\n' "$*" >>"${SNIPPET_CMD_LOG:?}"
EOF
cat >"$TMP/bin/opkg" <<'EOF'
#!/bin/sh
printf 'opkg %s\n' "$*" >>"${SNIPPET_CMD_LOG:?}"
EOF
cat >"$TMP/bin/apk" <<'EOF'
#!/bin/sh
printf 'apk %s\n' "$*" >>"${SNIPPET_CMD_LOG:?}"
EOF
chmod +x "$TMP/bin/wget" "$TMP/bin/opkg-key" "$TMP/bin/opkg" "$TMP/bin/apk"

sandbox_snippet() {
	local fake="$1"
	# Placeholder first so a fake root under /tmp is not rewritten twice.
	printf '%s\n' "$snippet" |
		sed 's|/etc/|__FWLIVE_ETC__/|g; s|/tmp/|__FWLIVE_TMP__/|g' |
		sed "s|__FWLIVE_ETC__|${fake}/etc|g; s|__FWLIVE_TMP__|${fake}/tmp|g"
}

run_snippet() {
	local fake="$1" release="$2"
	mkdir -p "$fake/etc" "$fake/tmp" "$fake/etc/opkg"
	printf "DISTRIB_RELEASE='%s'\n" "$release" >"$fake/etc/openwrt_release"
	: >"$TMP/cmd.log"
	export SNIPPET_CMD_LOG="$TMP/cmd.log"
	export PATH="$TMP/bin:$PATH"
	set +e
	sandbox_snippet "$fake" | sh >"$fake/out" 2>"$fake/err"
	rc=$?
	set -e
}

# 24.10 opkg: append the feed line. A pre-existing fwlive line is kept.
fake="$TMP/owrt-2410"
mkdir -p "$fake/etc/opkg"
printf '%s\n' \
	'src/gz fwlive https://lucas-albers-lz4.github.io/fwlive-packages/23.05' \
	'src/gz other http://example/packages' \
	>"$fake/etc/opkg/customfeeds.conf"
run_snippet "$fake" '24.10.8'
if [[ "$rc" -eq 0 ]]; then
	ok "24.10.8 snippet exits 0"
else
	bad "24.10.8 snippet rc=$rc ($(cat "$fake/err"))"
fi
grep -Fq 'wget -O ' "$TMP/cmd.log" && grep -Fq '/fwlive.key https://lucas-albers-lz4.github.io/fwlive-packages/public.key' "$TMP/cmd.log" \
	|| bad "24.10 must wget public.key ($(cat "$TMP/cmd.log"))"
grep -Fq 'opkg-key add ' "$TMP/cmd.log" && grep -Fq '/fwlive.key' "$TMP/cmd.log" \
	|| bad "24.10 must opkg-key add ($(cat "$TMP/cmd.log"))"
grep -Fq 'opkg update' "$TMP/cmd.log" && grep -Fq 'opkg install luci-app-fwlive' "$TMP/cmd.log" \
	|| bad "24.10 must opkg update && install ($(cat "$TMP/cmd.log"))"
grep -Fq 'apk ' "$TMP/cmd.log" && bad "24.10 must not call apk ($(cat "$TMP/cmd.log"))"
fw_n="$(grep -c '^src/gz fwlive ' "$fake/etc/opkg/customfeeds.conf" || true)"
[[ "$fw_n" -eq 2 ]] || bad "24.10 appends a fwlive line and keeps the old one (got $fw_n)"
grep -Fxq 'src/gz fwlive https://lucas-albers-lz4.github.io/fwlive-packages/24.10' \
	"$fake/etc/opkg/customfeeds.conf" \
	|| bad "24.10 customfeeds must point at /24.10 ($(cat "$fake/etc/opkg/customfeeds.conf"))"
grep -Fxq 'src/gz fwlive https://lucas-albers-lz4.github.io/fwlive-packages/23.05' \
	"$fake/etc/opkg/customfeeds.conf" \
	|| bad "24.10 must keep the pre-existing fwlive line"
grep -Fxq 'src/gz other http://example/packages' "$fake/etc/opkg/customfeeds.conf" \
	|| bad "24.10 must preserve unrelated opkg feeds"

# A failed key download stops before opkg-key.
fake="$TMP/owrt-wget-fail"
mkdir -p "$fake/etc/opkg"
SNIPPET_WGET_FAIL=1 run_snippet "$fake" '24.10.8'
unset SNIPPET_WGET_FAIL
if [[ "$rc" -ne 0 ]]; then
	ok "failed wget exits nonzero"
else
	bad "failed wget must exit nonzero"
fi
grep -Fq 'opkg-key ' "$TMP/cmd.log" && bad "failed wget must not run opkg-key ($(cat "$TMP/cmd.log"))"
grep -Fq 'opkg ' "$TMP/cmd.log" && bad "failed wget must not run opkg ($(cat "$TMP/cmd.log"))"

# 23.05 uses the same opkg path with its own feed directory.
fake="$TMP/owrt-2305"
run_snippet "$fake" '23.05.5'
if [[ "$rc" -eq 0 ]]; then
	ok "23.05.5 snippet exits 0"
else
	bad "23.05.5 snippet rc=$rc ($(cat "$fake/err"))"
fi
grep -Fq 'wget -O ' "$TMP/cmd.log" && grep -Fq '/fwlive.key https://lucas-albers-lz4.github.io/fwlive-packages/public.key' "$TMP/cmd.log" \
	|| bad "23.05 must wget public.key ($(cat "$TMP/cmd.log"))"
grep -Fq 'opkg update' "$TMP/cmd.log" && grep -Fq 'opkg install luci-app-fwlive' "$TMP/cmd.log" \
	|| bad "23.05 must opkg update && install ($(cat "$TMP/cmd.log"))"
grep -Fq 'apk ' "$TMP/cmd.log" && bad "23.05 must not call apk ($(cat "$TMP/cmd.log"))"
grep -Fxq 'src/gz fwlive https://lucas-albers-lz4.github.io/fwlive-packages/23.05' \
	"$fake/etc/opkg/customfeeds.conf" \
	|| bad "23.05 customfeeds must point at /23.05 ($(cat "$fake/etc/opkg/customfeeds.conf"))"

# 25.12 apk: overwrite fwlive.list.
fake="$TMP/owrt-2512"
mkdir -p "$fake/etc/apk/repositories.d"
printf '%s\n' 'https://example.invalid/stale.adb' >"$fake/etc/apk/repositories.d/fwlive.list"
run_snippet "$fake" '25.12.5'
if [[ "$rc" -eq 0 ]]; then
	ok "25.12.5 snippet exits 0"
else
	bad "25.12.5 snippet rc=$rc ($(cat "$fake/err"))"
fi
grep -Fq 'wget -O ' "$TMP/cmd.log" && grep -Fq '/fwlive-feed.rsa.pub https://lucas-albers-lz4.github.io/fwlive-packages/fwlive-feed.rsa.pub' "$TMP/cmd.log" \
	|| bad "25.12 must wget fwlive-feed.rsa.pub ($(cat "$TMP/cmd.log"))"
grep -Fq 'apk update' "$TMP/cmd.log" && grep -Fq 'apk add luci-app-fwlive' "$TMP/cmd.log" \
	|| bad "25.12 must apk update && add ($(cat "$TMP/cmd.log"))"
grep -Fq 'opkg ' "$TMP/cmd.log" && bad "25.12 must not call opkg ($(cat "$TMP/cmd.log"))"
grep -Fxq 'https://lucas-albers-lz4.github.io/fwlive-packages/25.12/all/packages.adb' \
	"$fake/etc/apk/repositories.d/fwlive.list" \
	|| bad "25.12 fwlive.list must be the packages.adb URL ($(cat "$fake/etc/apk/repositories.d/fwlive.list"))"
[[ -f "$fake/etc/apk/keys/fwlive-feed.rsa.pub" ]] \
	|| bad "25.12 must install the apk trust anchor"

# Unsupported lines fail closed without package-manager calls.
fake="$TMP/owrt-2102"
run_snippet "$fake" '21.02.7'
if [[ "$rc" -ne 0 ]]; then
	ok "21.02.7 snippet fails closed"
else
	bad "21.02.7 snippet must exit nonzero"
fi
[[ ! -s "$TMP/cmd.log" ]] || bad "21.02 must not wget or install ($(cat "$TMP/cmd.log"))"
grep -Fq 'unsupported' "$fake/err" || bad "21.02 must say unsupported ($(cat "$fake/err"))"

fake="$TMP/owrt-snap"
run_snippet "$fake" 'SNAPSHOT'
[[ "$rc" -ne 0 ]] || bad "SNAPSHOT snippet must exit nonzero"
[[ ! -s "$TMP/cmd.log" ]] || bad "SNAPSHOT must not wget or install ($(cat "$TMP/cmd.log"))"

if [[ "$fail" -ne 0 ]]; then
	echo "readme-feed-install-snippet.test.sh failed" >&2
	exit 1
fi
echo "OK: README feed install snippet covers opkg and apk"

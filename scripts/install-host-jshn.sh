#!/usr/bin/env bash
# Build the pinned OpenWrt libubox jshn utility for use by host-side tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_FILE="${ROOT}/scripts/jshn-pins.txt"
PIN_SHA256="dfd4389cd5a8e7cc54e8851ebe971c3602d1487986235103ff28aadc23dde5a9"
PREFIX="${FWLIVE_JSHN_PREFIX:-${HOME}/.cache/fwlive-jshn}"
REPOSITORY="https://github.com/openwrt/libubox.git"
DEFAULT_RELEASE="24.10"

die() { echo "install-host-jshn: $*" >&2; exit 1; }
usage() {
	cat <<'EOF'
Usage: install-host-jshn.sh [--all | --release RELEASE]

Build pinned libubox jshn binaries under FWLIVE_JSHN_PREFIX.
EOF
}
verify_pin_file() {
	local actual lines
	[[ -f "$PIN_FILE" ]] || die "pin manifest missing: $PIN_FILE"
	actual="$(sha256sum "$PIN_FILE" | awk '{print $1}')"
	[[ "$actual" == "$PIN_SHA256" ]] || die "pin manifest integrity check failed"
	lines="$(awk '!/^([[:space:]]*#|[[:space:]]*$)/ { if (NF != 2 || $1 !~ /^(21\.02|22\.03|23\.05|24\.10|25\.12)$/ || $2 !~ /^[0-9a-f]{40}$/) exit 1; n++ } END { print n+0 }' "$PIN_FILE")" || die "invalid pin manifest format"
	[[ "$lines" == 5 ]] || die "pin manifest must contain five release pins"
}
pin_for() { awk -v release="$1" '$1 == release { print $2; found=1 } END { if (!found) exit 1 }' "$PIN_FILE"; }
require_tools() {
	local tool
	for tool in git cmake cc sha256sum; do command -v "$tool" >/dev/null 2>&1 || die "required host tool unavailable: $tool"; done
}
install_release() (
	local release="$1" commit dest tmp src build stage jshn jshn_sh
	commit="$(pin_for "$release")" || die "unsupported release: $release"
	dest="${PREFIX}/${release}"
	if [[ -e "$dest" ]]; then
		[[ -f "$dest/manifest" && -x "$dest/bin/jshn" && -f "$dest/share/jshn.sh" ]] || die "incomplete installation exists for ${release}; remove it before retrying"
		awk -F= -v c="$commit" -v r="$release" '$1 == "release" { rr=$2 } $1 == "commit" { cc=$2 } END { exit !(rr == r && cc == c) }' "$dest/manifest" || die "manifest pin mismatch for ${release}"
		jshn="$(sha256sum "$dest/bin/jshn" | awk '{print $1}')"; jshn_sh="$(sha256sum "$dest/share/jshn.sh" | awk '{print $1}')"
		awk -F= -v a="$jshn" -v b="$jshn_sh" '$1 == "jshn_sha256" { ja=$2 } $1 == "jshn_sh_sha256" { jb=$2 } END { exit !(ja == a && jb == b) }' "$dest/manifest" || die "artifact integrity check failed for ${release}"
		(cd "$dest" && sha256sum -c artifacts.sha256 >/dev/null) || die "artifact integrity check failed for ${release}"
		"$dest/bin/jshn" -r '{}' >/dev/null || die "installed jshn cannot run for ${release}"
		echo "${release}: already installed and verified"; return
	fi
	mkdir -p "$PREFIX"
	tmp="$(mktemp -d "${PREFIX}/.build-${release}.XXXXXX")"
	trap 'rm -rf "$tmp"' EXIT
	src="${tmp}/src"; build="${tmp}/build"; stage="${tmp}/stage"
	git init -q "$src"; git -C "$src" remote add origin "$REPOSITORY"; git -C "$src" fetch -q --depth=1 origin "$commit"; git -C "$src" checkout -q --detach "$commit"
	[[ "$(git -C "$src" rev-parse HEAD)" == "$commit" ]] || die "checked out commit does not match pin"
	# The dynamic loader expands ORIGIN at runtime.
	# shellcheck disable=SC2016
	cmake -S "$src" -B "$build" -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$stage" -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib' >/dev/null
	cmake --build "$build" --parallel "${FWLIVE_JSHN_JOBS:-2}" >/dev/null; cmake --install "$build" >/dev/null
	[[ -x "$stage/bin/jshn" ]] || die "libubox build did not produce jshn"; [[ -f "$stage/share/libubox/jshn.sh" ]] || die "libubox build did not produce jshn.sh"
	mkdir -p "$stage/final/bin" "$stage/final/share" "$stage/final/lib"; cp "$stage/bin/jshn" "$stage/final/bin/jshn"; cp "$stage/share/libubox/jshn.sh" "$stage/final/share/jshn.sh"; cp -a "$stage/lib/." "$stage/final/lib/"; chmod 755 "$stage/final/bin/jshn"
	jshn="$(sha256sum "$stage/final/bin/jshn" | awk '{print $1}')"; jshn_sh="$(sha256sum "$stage/final/share/jshn.sh" | awk '{print $1}')"
	{ printf 'release=%s\n' "$release"; printf 'commit=%s\n' "$commit"; printf 'source=%s\n' "$REPOSITORY"; printf 'jshn_sha256=%s\n' "$jshn"; printf 'jshn_sh_sha256=%s\n' "$jshn_sh"; } > "$stage/final/manifest"
	(cd "$stage/final" && find bin share lib -type f -exec sha256sum {} + > artifacts.sha256)
	mv "$stage/final" "$dest"; echo "${release}: installed at ${dest}"
)
all=0; release="$DEFAULT_RELEASE"
while [[ $# -gt 0 ]]; do
	case "$1" in
		--all) all=1; shift ;;
		--release) [[ $# -ge 2 ]] || die "--release requires a value"; release="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done
[[ $all -eq 0 || "$release" == "$DEFAULT_RELEASE" ]] || die "--all cannot be combined with --release"
verify_pin_file; require_tools
if [[ $all -eq 1 ]]; then
	for release in 21.02 22.03 23.05 24.10 25.12; do install_release "$release"; done
else
	install_release "$release"
fi

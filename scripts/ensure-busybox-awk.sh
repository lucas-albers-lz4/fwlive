#!/usr/bin/env bash
# Print a directory whose `awk` is BusyBox >= 1.37.
# Ubuntu's busybox package is 1.36.1, which does not reproduce the 1.37
# gsub class (#763 / #879). Do not point this lane at that binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${FWLIVE_BUSYBOX_AWK_DIR:-${ROOT}/.cache/busybox-awk-1.37}"
URL="${FWLIVE_BUSYBOX_AWK_URL:-https://snapshot.debian.org/file/3827ed7fbd1b3928d5cb45bbe390c27862193e70}"
PIN_FILE="${ROOT}/scripts/busybox-awk-1.37.sha256"
if [[ -n "${FWLIVE_BUSYBOX_AWK_SHA256:-}" ]]; then
	SHA256="$FWLIVE_BUSYBOX_AWK_SHA256"
else
	read -r SHA256 _ <"$PIN_FILE"
fi
BB="${CACHE}/busybox-static"
BIN="${CACHE}/bin"
AWK="${BIN}/awk"
DEB_NAME="busybox-static_1.37.0-6+b9_amd64.deb"
DEB="${CACHE}/${DEB_NAME}"

busybox_awk_version_ok() {
	local banner major minor
	banner="$("$1" 2>/dev/null | head -1 || true)"
	[[ "$banner" =~ BusyBox\ v([0-9]+)\.([0-9]+) ]] || return 1
	major="${BASH_REMATCH[1]}"
	minor="${BASH_REMATCH[2]}"
	(( major > 1 || (major == 1 && minor >= 37) ))
}

for tool in curl sha256sum ar tar xz; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "ensure-busybox-awk: missing host tool '${tool}' (install curl, coreutils, binutils, tar, and xz-utils)" >&2
		exit 1
	fi
done
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
	echo "ensure-busybox-awk: FWLIVE_BUSYBOX_AWK_SHA256 must be 64 lowercase hex characters" >&2
	exit 1
fi

mkdir -p "$CACHE" "$BIN"
extract="$(mktemp -d)"
download=""
bb_tmp=""
awk_tmp=""
cleanup() {
	rm -rf "$extract"
	[[ -z "$download" ]] || rm -f "$download"
	[[ -z "$bb_tmp" ]] || rm -f "$bb_tmp"
	[[ -z "$awk_tmp" ]] || rm -f "$awk_tmp"
}
trap cleanup EXIT

deb_sha256_matches() {
	local got
	[[ -f "$DEB" ]] || return 1
	got="$(sha256sum "$DEB" | awk '{print $1}')"
	[[ "$got" == "$SHA256" ]]
}

# The extracted executable and wrapper live in the cache too, so never trust
# them on a cache hit. Verify the package on every run and recreate both files.
if ! deb_sha256_matches; then
	download="$(mktemp "${CACHE}/.${DEB_NAME}.XXXXXX")"
	curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 --retry-max-time 90 "$URL" -o "$download"
	got="$(sha256sum "$download" | awk '{print $1}')"
	if [[ "$got" != "$SHA256" ]]; then
		echo "ensure-busybox-awk: sha256 mismatch (got ${got})" >&2
		exit 1
	fi
	mv -f "$download" "$DEB"
	download=""
fi

tar_member="$(ar t "$DEB" | awk '/^data\.tar/{print; exit}')"
[[ -n "$tar_member" ]] || {
	echo "ensure-busybox-awk: deb has no data.tar" >&2
	exit 1
}
case "$tar_member" in
	*.xz) tar_flag=-J ;;
	*.gz) tar_flag=-z ;;
	*)
		echo "ensure-busybox-awk: unsupported ${tar_member}" >&2
		exit 1
		;;
esac
ar p "$DEB" "$tar_member" | tar -x "$tar_flag" -C "$extract"
install -m 0755 "${extract}/usr/bin/busybox" "${extract}/busybox-static"
busybox_awk_version_ok "${extract}/busybox-static" || {
	echo "ensure-busybox-awk: verified package does not contain BusyBox awk >= 1.37" >&2
	exit 1
}

bb_tmp="$(mktemp "${CACHE}/.busybox-static.XXXXXX")"
install -m 0755 "${extract}/busybox-static" "$bb_tmp"
mv -f "$bb_tmp" "$BB"
bb_tmp=""

awk_tmp="$(mktemp "${BIN}/.awk.XXXXXX")"
cat >"$awk_tmp" <<EOF
#!/bin/sh
exec $(printf '%q' "$BB") awk "\$@"
EOF
chmod 0755 "$awk_tmp"
mv -f "$awk_tmp" "$AWK"
awk_tmp=""
printf '%s\n' "$BIN"

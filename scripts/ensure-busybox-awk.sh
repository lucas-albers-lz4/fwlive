#!/usr/bin/env bash
# Print a directory whose `awk` is BusyBox >= 1.37.
# Ubuntu's busybox package is 1.36.1, which does not reproduce the 1.37
# gsub class (#763 / #879). Do not point this lane at that binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${FWLIVE_BUSYBOX_AWK_DIR:-${ROOT}/.cache/busybox-awk-1.37}"
URL="${FWLIVE_BUSYBOX_AWK_URL:-https://deb.debian.org/debian/pool/main/b/busybox/busybox-static_1.37.0-6+b9_amd64.deb}"
SHA256="${FWLIVE_BUSYBOX_AWK_SHA256:-598a3fd92bdafc34cd81196b2952ad36e910e47a4ecf162f8ce5e8e262598e53}"
BB="${CACHE}/busybox-static"
BIN="${CACHE}/bin"
AWK="${BIN}/awk"

busybox_awk_version_ok() {
	local banner major minor
	banner="$("$1" 2>/dev/null | head -1 || true)"
	[[ "$banner" =~ BusyBox\ v([0-9]+)\.([0-9]+) ]] || return 1
	major="${BASH_REMATCH[1]}"
	minor="${BASH_REMATCH[2]}"
	(( major > 1 || (major == 1 && minor >= 37) ))
}

if [[ -x "$BB" ]] && busybox_awk_version_ok "$BB" && [[ -x "$AWK" ]]; then
	printf '%s\n' "$BIN"
	exit 0
fi

mkdir -p "$CACHE" "$BIN"
deb="$(mktemp)"
extract="$(mktemp -d)"
trap 'rm -rf "$deb" "$extract"' EXIT
curl -fsSL "$URL" -o "$deb"
got="$(sha256sum "$deb" | awk '{print $1}')"
if [[ "$got" != "$SHA256" ]]; then
	echo "ensure-busybox-awk: sha256 mismatch (got ${got})" >&2
	exit 1
fi
tar_member="$(ar t "$deb" | awk '/^data\.tar/{print; exit}')"
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
ar p "$deb" "$tar_member" | tar -x "$tar_flag" -C "$extract"
install -m 0755 "${extract}/usr/bin/busybox" "$BB"
rm -rf "$extract"
busybox_awk_version_ok "$BB" || {
	echo "ensure-busybox-awk: ${BB} is not BusyBox awk >= 1.37" >&2
	exit 1
}
cat >"$AWK" <<EOF
#!/bin/sh
exec $(printf '%q' "$BB") awk "\$@"
EOF
chmod 0755 "$AWK"
printf '%s\n' "$BIN"

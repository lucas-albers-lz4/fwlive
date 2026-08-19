#!/usr/bin/env bash
# Run shellcheck on shipped rpcd/libexec shell scripts (#86).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBEXEC="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec"

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "Install shellcheck (e.g. apt install shellcheck) to run this gate." >&2
	exit 1
fi

# Enumerate by discovery, not a fixed list, so a newly added script cannot
# silently escape this gate (it previously named 4 files explicitly). The
# shipped rpcd entrypoint `rpcd/fwlive` has no extension, so match *.sh OR
# that exact name. Do not use -x: sourced paths are runtime-resolved
# ($FILTER_DIR / $LOGGING_SH).
find "$LIBEXEC" -type f \( -name '*.sh' -o -name 'fwlive' \) -print0 \
	| xargs -0 -r shellcheck -s sh

echo "fwlive shellcheck OK" >&2

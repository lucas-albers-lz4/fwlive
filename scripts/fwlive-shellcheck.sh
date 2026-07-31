#!/usr/bin/env bash
# Run shellcheck on shipped rpcd/libexec shell scripts (#86).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBEXEC="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec"

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "Install shellcheck (e.g. apt install shellcheck) to run this gate." >&2
	exit 1
fi

# Do not use -x: sourced paths are runtime-resolved ($FILTER_DIR / $LOGGING_SH).
shellcheck -s sh \
	"$LIBEXEC/fwlive-log-filter.sh" \
	"$LIBEXEC/fwlive-logging.sh" \
	"$LIBEXEC/fwlive-is-firewall-event.sh" \
	"$LIBEXEC/rpcd/fwlive"

echo "fwlive shellcheck OK" >&2

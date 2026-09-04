#!/usr/bin/env bash
# Normalize #: reference paths in luci-app-fwlive.pot to repo-relative form.
#
# i18n-scan.pl embeds absolute scan-root paths (e.g. /home/.../fwlive/openwrt-feed/...).
# That makes the checked-in catalog machine-specific and noisy across developers.
# This script rewrites #: lines to start at openwrt-feed/ (or applications/ if
# already luci-shaped). Idempotent.
#
# Usage:
#   ./scripts/normalize-pot-paths.sh
#   ./scripts/normalize-pot-paths.sh path/to/luci-app-fwlive.pot
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POT="${1:-$ROOT/openwrt-feed/luci-app-fwlive/po/templates/luci-app-fwlive.pot}"

[[ -f "$POT" ]] || { echo "error: pot not found: $POT" >&2; exit 1; }

tmp="$(mktemp)"
# Strip any absolute prefix up through openwrt-feed/ or applications/.
# Also collapse accidental doubled prefixes.
sed -E \
	-e 's|^(#: ).*/openwrt-feed/|\1openwrt-feed/|' \
	-e 's|^(#: ).*/applications/luci-app-fwlive/|\1applications/luci-app-fwlive/|' \
	"$POT" > "$tmp"

if cmp -s "$POT" "$tmp"; then
	rm -f "$tmp"
	echo "normalize-pot-paths: already relative ($POT)"
	exit 0
fi

mv "$tmp" "$POT"
echo "normalize-pot-paths: rewrote #: refs in $POT"
# Fail closed if anything absolute remains under common home/tmp roots.
if grep -E '^#: (/home/|/Users/|/tmp/|/var/)' "$POT" >/dev/null; then
	echo "error: absolute #: refs remain after normalize" >&2
	grep -E '^#: (/home/|/Users/|/tmp/|/var/)' "$POT" | head -5 >&2
	exit 1
fi

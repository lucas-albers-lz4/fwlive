#!/usr/bin/env bash
# Regenerate derived files from core/fwlive-log.js (single source of truth).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_shell="$(mktemp)"
tmp_luci="$(mktemp)"
trap 'rm -f "$tmp_shell" "$tmp_luci"' EXIT
node "$ROOT/scripts/gen-shell-classifier.js" > "$tmp_shell"
node "$ROOT/scripts/gen-luci-wrapper.js" > "$tmp_luci"
mv "$tmp_shell" "$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.sh"
mv "$tmp_luci" "$ROOT/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js"
echo "Regenerated shell classifier + verified LuCI wrapper. Review git diff and commit."

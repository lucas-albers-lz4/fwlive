#!/usr/bin/env bash
# From core/fwlive-log.js CLASSIFY_SPEC:
#   - regenerate the shell classifier (true codegen)
#   - verify the hand-maintained LuCI wrapper (gate; does not transform it)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_shell="$(mktemp)"
tmp_luci="$(mktemp)"
trap 'rm -f "$tmp_shell" "$tmp_luci"' EXIT
node "$ROOT/scripts/gen-shell-classifier.js" > "$tmp_shell"
node "$ROOT/scripts/gen-luci-wrapper.js" > "$tmp_luci"
mv "$tmp_shell" "$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.sh"
mv "$tmp_luci" "$ROOT/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js"
echo "Regenerated shell classifier + verified LuCI wrapper (gate). Review git diff and commit."

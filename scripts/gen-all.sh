#!/usr/bin/env bash
# From core/fwlive-log.js CLASSIFY_SPEC:
#   - regenerate the shell classifier (true codegen)
#   - verify the hand-maintained LuCI wrapper (gate; does not transform it)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_shell="$(mktemp)"
tmp_awk="$(mktemp)"
tmp_luci="$(mktemp)"
trap 'rm -f "$tmp_shell" "$tmp_awk" "$tmp_luci"' EXIT
node "$ROOT/scripts/gen-shell-classifier.js" > "$tmp_shell"
node "$ROOT/scripts/gen-shell-classifier.js" --awk > "$tmp_awk"
node "$ROOT/scripts/gen-luci-wrapper.js" > "$tmp_luci"
chmod 0644 "$tmp_shell"
chmod 0644 "$tmp_awk"
mv "$tmp_shell" "$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.sh"
mv "$tmp_awk" "$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.awk"
mv "$tmp_luci" "$ROOT/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js"
echo "Regenerated shell classifier + awk asset + verified LuCI wrapper (gate). Review git diff and commit."

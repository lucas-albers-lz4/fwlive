#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/qemu-uci-stage-revert-smoke.sh"
HELPER="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh"

[[ -x "$SCRIPT" ]] || { echo "UCI stage/revert smoke is not executable" >&2; exit 1; }
bash -n "$SCRIPT"
shellcheck --severity=warning "$SCRIPT"
grep -Fq 'wan_log_revert_staged_option_if_ours wan 3' "$SCRIPT" \
	|| { echo 'guest smoke must exercise option-scoped set cleanup against real UCI' >&2; exit 1; }
grep -Fq "wan_log_revert_staged_option_if_ours wan ''" "$SCRIPT" \
	|| { echo 'guest smoke must exercise option-scoped delete cleanup against real UCI' >&2; exit 1; }
grep -Fq 'uci add_list firewall.wan.log=3' "$SCRIPT" \
	|| { echo 'guest smoke must cover same-option list additions' >&2; exit 1; }
grep -Fq 'uci del_list firewall.wan.log=2' "$SCRIPT" \
	|| { echo 'guest smoke must cover same-option list deletions' >&2; exit 1; }
grep -Fq "firewall.wan.description='foreign'" "$SCRIPT" \
	|| { echo 'guest smoke must verify unrelated staged changes survive' >&2; exit 1; }
grep -Fq 'ambiguous same-option staging was reverted' "$SCRIPT" \
	|| { echo 'guest smoke must cover same-option preservation' >&2; exit 1; }
grep -Fq -- '-C "$UCI_TEST_DIR/overrides"' "$SCRIPT" \
	|| { echo 'guest smoke must isolate the UCI override directory' >&2; exit 1; }
grep -Fq '/tmp/.uci/firewall' "$SCRIPT" \
	|| { echo 'guest smoke must refuse ambient firewall deltas' >&2; exit 1; }
helper_revert="$(awk '/^wan_log_revert_staged_option_if_ours\(\)/,/^}/' "$HELPER")"
printf '%s\n' "$helper_revert" | grep -Fq 'uci -q revert "firewall.${_zone}.log"' \
	|| { echo 'production helper must revert only the exact log option' >&2; exit 1; }
printf '%s\n' "$helper_revert" | grep -Fq 'uci -q changes firewall' \
	|| { echo 'production helper must verify cleanup with fresh UCI changes' >&2; exit 1; }
echo 'qemu UCI stage/revert source-contract checks passed'

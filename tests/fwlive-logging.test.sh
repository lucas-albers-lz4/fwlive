#!/usr/bin/env bash
# Unit tests for fwlive-logging.sh helpers (no UCI/firewall required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGGING_SH="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh"
RPCD="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive"

die() { echo "fwlive-logging test FAIL: $*" >&2; exit 1; }
ok() { echo "fwlive-logging test OK: $*"; }

json_escape() {
	awk 'BEGIN { RS = ""; ORS = "" }
	{
		for (i = 1; i <= length($0); i++) {
			c = substr($0, i, 1)
			if (c == "\\") printf "\\\\"
			else if (c == "\"") printf "\\\""
			else if (c == "\t") printf "\\t"
			else if (c == "\r") printf "\\r"
			else if (c == "\n") printf "\\n"
			else printf "%s", c
		}
	}'
}

. "$LOGGING_SH"

run_logging_selftest || die "run_logging_selftest"
ok "filter log bit logic"

out=$(build_logging_status_json)
case "$out" in
	*'"wan_log":'*) ;;
	*) die "logging_status JSON missing wan_log: $out" ;;
esac
case "$out" in
	*'"blockers":'*) ;;
	*) die "logging_status JSON missing blockers: $out" ;;
esac
ok "build_logging_status_json shape"

sh "$RPCD" __selftest >/dev/null || die "rpcd __selftest"
ok "rpcd __selftest"

echo "fwlive-logging tests passed"

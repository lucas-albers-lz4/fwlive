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

# restore_wan_zone_log: empty previous => delete; non-empty => set + commit
UCI_LOG=()
uci() {
	UCI_LOG+=("$*")
	return 0
}
UCI_LOG=()
restore_wan_zone_log '@zone[0]' ''
joined="${UCI_LOG[*]}"
case "$joined" in
	*'-q delete firewall.@zone[0].log'*'commit firewall'*) ;;
	*) die "restore empty previous expected delete+commit, got: $joined" ;;
esac
UCI_LOG=()
restore_wan_zone_log '@zone[1]' '3'
joined="${UCI_LOG[*]}"
case "$joined" in
	*'-q set firewall.@zone[1].log=3'*'commit firewall'*) ;;
	*) die "restore value expected set+commit, got: $joined" ;;
esac
unset -f uci
ok "restore_wan_zone_log stubs"

# find_wan_zone_section: named zone + anonymous zone (issue #168)
uci() {
	case "$*" in
		'-q show firewall')
			cat <<'EOF'
firewall.wan=zone
firewall.wan.name='wan'
firewall.wan.network='wan'
firewall.@zone[1]=zone
firewall.@zone[1].name='lan'
EOF
			;;
		'-q get firewall.wan')
			printf 'zone\n'
			;;
		*) return 1 ;;
	esac
}
got=$(find_wan_zone_section)
[ "$got" = "wan" ] || die "named wan zone expected 'wan', got '$got'"
ok "find_wan_zone_section named zone"

uci() {
	case "$*" in
		'-q show firewall')
			cat <<'EOF'
firewall.@zone[0]=zone
firewall.@zone[0].name='wan'
firewall.@zone[1]=zone
firewall.@zone[1].name='lan'
EOF
			;;
		'-q get firewall.@zone[0]')
			printf 'zone\n'
			;;
		*) return 1 ;;
	esac
}
got=$(find_wan_zone_section)
[ "$got" = "@zone[0]" ] || die "anonymous wan zone expected @zone[0], got '$got'"
ok "find_wan_zone_section anonymous zone"

# firewall_changes_pending + enable refuse (issue #168)
PENDING_STAGED=1
UCI_COMMITTED=0
uci() {
	case "$*" in
		'-q changes firewall')
			[ "$PENDING_STAGED" = 1 ] && printf "firewall.@rule[0].name='staged'\n"
			;;
		'-q show firewall')
			printf "firewall.@zone[0]=zone\nfirewall.@zone[0].name='wan'\n"
			;;
		'-q get firewall.@zone[0]')
			printf 'zone\n'
			;;
		'-q get firewall.@zone[0].log')
			printf ''
			;;
		'set firewall.@zone[0].log='*)
			die "uci set must not run when changes pending"
			;;
		'commit firewall')
			UCI_COMMITTED=1
			;;
		*) return 0 ;;
	esac
}
check_nf_log_ipv4() { return 0; }
check_nf_log_ipv6() { return 0; }
acquire_wan_log_lock() { return 0; }
release_wan_log_lock() { return 0; }
out=$(enable_wan_logging)
case "$out" in
	*'"error":"firewall_changes_pending"'*) ;;
	*) die "enable with pending expected firewall_changes_pending, got: $out" ;;
esac
[ "$UCI_COMMITTED" = "0" ] || die "pending enable must not commit"
ok "enable refuses when firewall changes pending"

# restore refuses when pending (does not commit staged delta)
UCI_LOG=()
uci() {
	UCI_LOG+=("$*")
	case "$*" in
		'-q changes firewall') printf "firewall.@rule[0]=rule\n" ;;
		*) return 0 ;;
	esac
}
restore_wan_zone_log '@zone[0]' '' || true
joined="${UCI_LOG[*]}"
case "$joined" in
	*'commit firewall'*) die "restore must not commit while pending: $joined" ;;
esac
ok "restore_wan_zone_log skips commit when pending"
unset -f uci check_nf_log_ipv4 check_nf_log_ipv6 acquire_wan_log_lock release_wan_log_lock

sh "$RPCD" __selftest >/dev/null || die "rpcd __selftest"
ok "rpcd __selftest"

echo "fwlive-logging tests passed"

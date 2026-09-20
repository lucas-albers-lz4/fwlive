#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Prove the fwlive ACL at the installed LuCI/uhttpd session boundary.
#
# This is intentionally a lab/manual check. Root SSH ubus calls cannot prove
# that rpcd assigned the fwlive ACL to an authenticated session, or withheld
# it from a session without the grant.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
SSH_PORT="${OPENWRT_SSH_PORT:-2222}"
HTTP_PORT="${OWRT_HOSTFWD_HTTP:-8080}"
SOURCE_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf '%s' unknown)"
GRANT_USER="${FWLIVE_ACL_GRANT_USER:-fwlive-acl-grant}"
DENY_USER="${FWLIVE_ACL_DENY_USER:-fwlive-acl-deny}"
# This password exists only for the temporary lab logins and is never printed.
TEST_PASSWORD="${FWLIVE_ACL_TEST_PASSWORD:-FwliveAclSession-2026}"

SSH_OPTS=(
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o ConnectTimeout=15
	-p "$SSH_PORT"
)
UBUS_URL="http://${HOST}:${HTTP_PORT}/ubus"
BACKUP=""
ORIGINAL_WAN_LOG=""

die() {
	echo "acl-session smoke FAIL: $*" >&2
	exit 1
}

ok() {
	echo "acl-session smoke OK: $*"
}

case "$GRANT_USER" in
	''|*[!A-Za-z0-9_-]*) die "FWLIVE_ACL_GRANT_USER must contain only letters, digits, '_' or '-'" ;;
esac
case "$DENY_USER" in
	''|*[!A-Za-z0-9_-]*) die "FWLIVE_ACL_DENY_USER must contain only letters, digits, '_' or '-'" ;;
esac
case "$TEST_PASSWORD" in
	''|*[!A-Za-z0-9._-]*) die "FWLIVE_ACL_TEST_PASSWORD contains unsupported shell characters" ;;
esac
[[ "$GRANT_USER" != "$DENY_USER" ]] || die "grant and deny users must differ"

usage() {
	cat <<'EOF'
Usage: scripts/qemu-acl-session-smoke.sh

Proves fwlive read/write method access through two temporary authenticated
LuCI/uhttpd `/ubus` sessions: one with the luci-app-fwlive ACL and one without.

Environment:
  OPENWRT_HOST       guest host (default: 127.0.0.1)
  OPENWRT_SSH_PORT   guest SSH port (default: 2222)
  OWRT_HOSTFWD_HTTP  guest LuCI HTTP port (default: 8080)
  FWLIVE_ACL_*       temporary usernames/password override (lab only)
EOF
}

if [[ "${1:-}" == --help ]]; then
	usage
	exit 0
fi

command -v curl >/dev/null 2>&1 || die "host curl is required"
command -v jq >/dev/null 2>&1 || die "host jq is required"
command -v ssh >/dev/null 2>&1 || die "host ssh is required"

ssh_guest() {
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

cleanup_guest() {
	set +e
	if [[ -n "$BACKUP" ]]; then
		# Discard any uncommitted UCI overlay before restoring the file. This
		# matters if the script exits after uci add but before uci commit.
		ssh_guest 'uci revert rpcd' >/dev/null 2>&1 || true
		if [[ "$ORIGINAL_WAN_LOG" == true ]]; then
			ssh_guest 'ubus call fwlive enable_wan_logging >/dev/null 2>&1' || true
		elif [[ "$ORIGINAL_WAN_LOG" == false ]]; then
			ssh_guest 'ubus call fwlive disable_wan_logging >/dev/null 2>&1' || true
		fi
		ssh_guest "cp '$BACKUP' /etc/config/rpcd && /etc/init.d/rpcd restart; rm -f '$BACKUP'" \
			>/dev/null 2>&1
	fi
}

trap cleanup_guest EXIT

ssh_guest 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU and install fwlive first"
ssh_guest 'test -x /usr/libexec/rpcd/fwlive && test -x /usr/sbin/uhttpd' \
	|| die "guest needs installed fwlive and uhttpd"

BACKUP_CANDIDATE="$(ssh_guest 'mktemp /tmp/fwlive-acl-session.XXXXXX')"
[[ -n "$BACKUP_CANDIDATE" ]] || die "could not allocate guest rpcd backup"
if ssh_guest "cp /etc/config/rpcd '$BACKUP_CANDIDATE'"; then
	# Do not arm the restore trap until the backup is known-good. Otherwise a
	# failed copy could restore an empty tempfile over /etc/config/rpcd.
	BACKUP="$BACKUP_CANDIDATE"
else
	ssh_guest "rm -f '$BACKUP_CANDIDATE'" >/dev/null 2>&1 || true
	die "could not copy the guest rpcd config"
fi
ORIGINAL_WAN_LOG="$(ssh_guest 'ubus call fwlive logging_status 2>/dev/null | jsonfilter -e '\''$.wan_log'\'' 2>/dev/null || true')"
case "$ORIGINAL_WAN_LOG" in
	true|false) ;;
	*) die "could not determine the guest WAN logging state" ;;
esac

PASSWORD_HASH="$(ssh_guest "uhttpd -m '$TEST_PASSWORD'" | tr -d '\r\n')"
[[ "$PASSWORD_HASH" == \$* ]] || die "guest uhttpd did not return a password hash"

add_login() {
	local username="$1"
	local section
	section="$(ssh_guest 'uci add rpcd login' | tr -d '\r\n')"
	case "$section" in
		cfg*) ;;
		*) die "unexpected rpcd login section: $section" ;;
	esac
	ssh_guest "uci set rpcd.$section.username='$username'; uci set rpcd.$section.password='$PASSWORD_HASH'"
	if [[ "$username" == "$GRANT_USER" ]]; then
		ssh_guest "uci add_list rpcd.$section.read='luci-app-fwlive'; uci add_list rpcd.$section.write='luci-app-fwlive'"
	else
		# Match an ordinary authenticated LuCI user while deliberately omitting
		# the application ACL under test.
		ssh_guest "uci add_list rpcd.$section.read='luci-base'"
	fi
}

add_login "$GRANT_USER"
add_login "$DENY_USER"
ssh_guest 'uci commit rpcd && /etc/init.d/rpcd restart'
sleep 1

ubus_http_call() {
	local payload="$1"
	curl -fsS --connect-timeout 10 --max-time 30 \
		-H 'Content-Type: application/json' \
		--data "$payload" "$UBUS_URL"
}

login_session() {
	local username="$1"
	local payload response code
	payload="$(jq -cn --arg user "$username" --arg password "$TEST_PASSWORD" \
		'{jsonrpc:"2.0",id:1,method:"call",params:["00000000000000000000000000000000","session","login",{username:$user,password:$password}]}')"
	response="$(ubus_http_call "$payload")"
	code="$(jq -r '.result[0] // 255' <<<"$response")"
	[[ "$code" == 0 ]] || die "login failed for $username: $response"
	jq -er '.result[1].ubus_rpc_session // empty' <<<"$response"
}

call_object() {
	local sid="$1"
	local object="$2"
	local method="$3"
	local payload
	payload="$(jq -cn --arg sid "$sid" --arg object "$object" --arg method "$method" \
		'{jsonrpc:"2.0",id:2,method:"call",params:[$sid,$object,$method,{}]}')"
	ubus_http_call "$payload"
}

call_fwlive() {
	call_object "$1" fwlive "$2"
}

rpc_status_code() {
	jq -r '.result[0] // .error.code // 255' <<<"$1"
}

assert_allowed() {
	local label="$1"
	local response="$2"
	local code
	code="$(rpc_status_code "$response")"
	[[ "$code" == 0 ]] || die "$label should be allowed, got: $response"
	ok "$label allowed (JSON-RPC result=0)"
}

assert_denied() {
	local label="$1"
	local response="$2"
	local code
	code="$(rpc_status_code "$response")"
	[[ "$code" == -32002 ]] || die "$label should be denied with JSON-RPC Access denied (-32002), got: $response"
	ok "$label denied (JSON-RPC error=$code)"
}

RELEASE="$(ssh_guest '. /etc/openwrt_release 2>/dev/null; printf "%s" "${DISTRIB_RELEASE:-unknown}"')"
ARCH="$(ssh_guest 'uname -m')"
echo "acl-session smoke guest=${RELEASE} arch=${ARCH} source=${SOURCE_SHA}"

GRANT_SID="$(login_session "$GRANT_USER")"
echo "acl-session smoke authenticated user=${GRANT_USER}"
assert_allowed "${GRANT_USER}: fwlive.logging_status" "$(call_fwlive "$GRANT_SID" logging_status)"
assert_allowed "${GRANT_USER}: fwlive.rules" "$(call_fwlive "$GRANT_SID" rules)"
assert_allowed "${GRANT_USER}: fwlive.poll" "$(call_fwlive "$GRANT_SID" poll)"
assert_allowed "${GRANT_USER}: fwlive.resolve" "$(call_fwlive "$GRANT_SID" resolve)"
assert_allowed "${GRANT_USER}: fwlive.enable_wan_logging" "$(call_fwlive "$GRANT_SID" enable_wan_logging)"
assert_allowed "${GRANT_USER}: fwlive.disable_wan_logging" "$(call_fwlive "$GRANT_SID" disable_wan_logging)"
assert_denied "${GRANT_USER}: log.read" "$(call_object "$GRANT_SID" log read)"

DENY_SID="$(login_session "$DENY_USER")"
echo "acl-session smoke authenticated user=${DENY_USER}"
assert_denied "${DENY_USER}: fwlive.logging_status" "$(call_fwlive "$DENY_SID" logging_status)"
assert_denied "${DENY_USER}: fwlive.enable_wan_logging" "$(call_fwlive "$DENY_SID" enable_wan_logging)"

ok "authenticated session ACL boundary verified; rpcd config will be restored"

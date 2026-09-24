#!/usr/bin/env bash
# Headless smoke test for luci-app-fwlive on a running QEMU guest.
#
#   ./scripts/qemu-smoke-fwlive.sh
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-smoke-fwlive.sh
#   FWLIVE_EXPECT_ARCH=x86_64 ./scripts/qemu-smoke-fwlive.sh
#   ./scripts/qemu-smoke-fwlive.sh --require-log-pipeline
#
# Checks: SSH, release, ubus fwlive poll/resolve, fwlive rules, LuCI static assets, optional ping log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
HTTP_PORT="${OWRT_HOSTFWD_HTTP:-8080}"
EXPECT_ARCH="${FWLIVE_EXPECT_ARCH:-}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")
REQUIRE_LOG_PIPELINE=0

usage() {
	cat <<EOF
Usage: qemu-smoke-fwlive.sh [--require-log-pipeline]

Options:
  --require-log-pipeline  fail if firewall setup, traffic, or parsing yields no rows
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--require-log-pipeline) REQUIRE_LOG_PIPELINE=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "unknown arg: $1" >&2; usage >&2; exit 1 ;;
	esac
done

die() { echo "smoke FAIL: $*" >&2; exit 1; }
ok() { echo "smoke OK: $*"; }

ssh_guest() {
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

# ubus exits 0 on method-level refusals. Require the success key. Reject an
# "error" field except on rules, where no_backend / rules_truncated still
# return a usable map (fw3/iptables guests).
ubus_method_ok() {
	local method="$1"
	local remote="$2"
	local key="$3"
	local allow_error="${4:-}"
	local body
	if ! body="$(ssh_guest "$remote")"; then
		die "ubus fwlive ${method} failed (rpcd plugin / ACL?)"
	fi
	if [[ -z "$body" ]]; then
		die "ubus fwlive ${method} returned an empty body"
	fi
	if printf '%s' "$body" | grep -Eq '"error"[[:space:]]*:'; then
		if [[ "$allow_error" != allow_error ]]; then
			die "ubus fwlive ${method} replied with error: ${body}"
		elif ! printf '%s' "$body" | grep -Eq '"error"[[:space:]]*:[[:space:]]*"(no_backend|rules_truncated)"'; then
			die "ubus fwlive ${method} replied with disallowed error: ${body}"
		fi
	fi
	if ! printf '%s' "$body" | grep -Eq "\"${key}\"[[:space:]]*:"; then
		die "ubus fwlive ${method} missing ${key}: ${body}"
	fi
	case "$key" in
		log)
			printf '%s' "$body" | grep -Eq '"log"[[:space:]]*:[[:space:]]*\[' \
				|| die "ubus fwlive ${method} log is not an array: ${body}"
			;;
		names | rules)
			printf '%s' "$body" | grep -Eq "\"${key}\"[[:space:]]*:[[:space:]]*\{" \
				|| die "ubus fwlive ${method} ${key} is not an object: ${body}"
			;;
	esac
	ok "ubus fwlive ${method}"
}

echo "== fwlive QEMU smoke (root@${HOST}:${PORT}) ==" >&2

ssh_guest 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU and run qemu-lab-prepare-image.sh if needed"

RELEASE="$(ssh_guest '. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE:-unknown}"')"
ARCH="$(ssh_guest 'uname -m')"
if [[ -n "$EXPECT_ARCH" && "$ARCH" != "$EXPECT_ARCH" ]]; then
	die "guest arch ${ARCH} != expected ${EXPECT_ARCH} (wrong QEMU/SSH port?)"
fi
ok "guest ${ARCH} OpenWrt ${RELEASE}"

ubus_method_ok poll \
	'ubus call fwlive poll '"'"'{"addresses":["20"]}'"'"'' \
	log
ubus_method_ok resolve \
	'ubus call fwlive resolve '"'"'{"addresses":["127.0.0.1"]}'"'"'' \
	names
ubus_method_ok rules 'ubus call fwlive rules' rules allow_error
ubus_method_ok logging_status 'ubus call fwlive logging_status' wan_zone

ssh_guest 'test -f /www/luci-static/resources/view/status/fwlive.js' \
	|| die "missing LuCI view JS"
ssh_guest 'test -f /www/luci-static/resources/fwlive/log.js' \
	|| die "missing fwlive/log.js"
ok "LuCI static assets"

MENU_JSON=/usr/share/luci/menu.d/luci-app-fwlive.json
ssh_guest "test -f '$MENU_JSON'" || die "missing LuCI menu.d entry"
# #53/#62/#70: menu must depend on ACL only — fs AND of nft+iptables hid the entry on stock fw3/fw4.
MENU_BODY="$(ssh_guest "cat '$MENU_JSON'")"
printf '%s' "$MENU_BODY" | grep -q 'Firewall Live View' \
	|| die "menu.d missing Firewall Live View title"
printf '%s' "$MENU_BODY" | grep -q 'luci-app-fwlive' \
	|| die "menu.d missing ACL depend luci-app-fwlive"
if printf '%s' "$MENU_BODY" | grep -qE '"fs"|/usr/sbin/nft|/usr/sbin/iptables'; then
	die "menu.d still has fs/nft/iptables depends (breaks fw3-only or fw4-only menus)"
fi
ok "LuCI menu.d ACL-only depends"

# Warm dispatcher (authenticated when possible) so index cache includes the node.
COOKIE_JAR="$(mktemp)"
cleanup_cookies() { rm -f "$COOKIE_JAR"; }
trap cleanup_cookies EXIT
# Empty-password lab: establish a session so /tmp/luci-indexcache*.json is written.
curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
	-d 'luci_username=root&luci_password=' \
	"http://${HOST}:${HTTP_PORT}/cgi-bin/luci" >/dev/null 2>&1 || true
HTTP_HEADERS="$(curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -D - -o /dev/null \
	"http://${HOST}:${HTTP_PORT}/cgi-bin/luci/admin/status/fwlive" 2>/dev/null || true)"
HTTP_CODE="$(printf '%s' "$HTTP_HEADERS" | awk 'toupper($1) ~ /^HTTP/ { print $2; exit }')"
if [[ -z "$HTTP_CODE" ]]; then
	die "LuCI page unreachable"
fi
case "$HTTP_CODE" in
	200|302|303) ok "LuCI page HTTP ${HTTP_CODE}" ;;
	403)
		if printf '%s' "$HTTP_HEADERS" | grep -qi 'x-luci-login-required'; then
			ok "LuCI page HTTP 403 (login required — dispatcher OK)"
		else
			die "LuCI page HTTP 403 (check uhttpd ucode_prefix in qemu-lab-prepare-image.sh)"
		fi
		;;
	*) die "LuCI page HTTP ${HTTP_CODE} (expected 200/302/403-login)" ;;
esac

# Prefer newest index cache (stale/other-language copies may exist).
CACHE_JSON="$(ssh_guest 'ls -1t /tmp/luci-indexcache*.json 2>/dev/null | head -1')"
if [[ -z "$CACHE_JSON" ]]; then
	die "no luci-indexcache after page hit — Status menu entry not verified"
fi
CACHE_BODY="$(ssh_guest "cat '$CACHE_JSON'")"
printf '%s' "$CACHE_BODY" | grep -q 'Firewall Live View' \
	|| die "LuCI index cache present but Firewall Live View missing"
ok "LuCI index cache lists Firewall Live View (Status menu)"

count_parsed_rows() {
	local raw rows node_cmd
	if ! raw="$("${ROOT}/scripts/fwlive-ubus-read.sh" --lines 30 2>/dev/null)"; then
		printf '0'
		return 1
	fi

	node_cmd="${NODE:-}"
	if [[ -z "$node_cmd" ]]; then
		if command -v node >/dev/null 2>&1; then
			node_cmd=node
		elif command -v nodejs >/dev/null 2>&1; then
			node_cmd=nodejs
		else
			printf '0'
			return 1
		fi
	fi
	if ! rows="$(printf '%s' "$raw" | "$node_cmd" -e '
		const value = JSON.parse(require("fs").readFileSync(0, "utf8"));
		if (!Array.isArray(value)) process.exit(2);
		process.stdout.write(String(value.length));
	' 2>/dev/null)"; then
		printf '0'
		return 1
	fi
	printf '%s' "$rows"
}

read_required_rows() {
	local raw rows node_cmd
	if ! raw="$("${ROOT}/scripts/fwlive-ubus-read.sh" --lines 30 2>&1)"; then
		printf '%s\n' "$raw" >&2
		die "firewall log read failed"
	fi

	node_cmd="${NODE:-}"
	if [[ -z "$node_cmd" ]]; then
		if command -v node >/dev/null 2>&1; then
			node_cmd=node
		elif command -v nodejs >/dev/null 2>&1; then
			node_cmd=nodejs
		else
			die "firewall log row validation requires node or nodejs"
		fi
	fi
	if ! rows="$(printf '%s' "$raw" | "$node_cmd" -e '
		const value = JSON.parse(require("fs").readFileSync(0, "utf8"));
		if (!Array.isArray(value)) process.exit(2);
		process.stdout.write(String(value.length));
	')"; then
		printf '%s\n' "$raw" >&2
		die "firewall log read returned invalid row JSON"
	fi
	printf '%s' "$rows"
}

wait_for_required_rows() {
	local backend="$1" attempt rows
	for attempt in 1 2 3 4 5; do
		rows="$(read_required_rows)"
		if [[ "$rows" -ge 1 ]]; then
			printf '%s' "$rows"
			return 0
		fi
		[[ "$attempt" -lt 5 ]] && sleep 1
	done
	die "firewall log pipeline produced zero parsed rows (${backend})"
}

run_required_log_pipeline() {
	local backend="$1" rows
	if [[ "$backend" == nft ]]; then
		"${ROOT}/scripts/fwlive-nft-ping-log.sh" add --ssh \
			|| die "firewall log rule setup failed (nft)"
	else
		"${ROOT}/scripts/fwlive-iptables-ping-log.sh" add --ssh \
			|| die "firewall log rule setup failed (iptables)"
	fi

	ssh_guest 'ping -c 3 -W 1 127.0.0.1 >/dev/null 2>&1' \
		|| die "firewall traffic generation failed (${backend})"
	rows="$(wait_for_required_rows "$backend")"
	ok "firewall log pipeline ${backend} (${rows} parsed row(s))"
}

run_optional_log_pipeline() {
	local backend="$1" rows
	if [[ "$backend" == nft ]]; then
		"${ROOT}/scripts/fwlive-nft-ping-log.sh" add --ssh >/dev/null 2>&1 || true
	else
		"${ROOT}/scripts/fwlive-iptables-ping-log.sh" add --ssh >/dev/null 2>&1 || true
	fi
	ssh_guest 'ping -c 3 -W 1 127.0.0.1 >/dev/null 2>&1' || true
	rows=0
	rows="$(count_parsed_rows)" || rows=0
	if [[ "${rows:-0}" -ge 1 ]]; then
		ok "firewall log pipeline ${backend} (${rows} parsed row(s))"
	else
		echo "smoke WARN: no parsed firewall rows yet (${backend} log rule may need traffic)" >&2
	fi
}

if ssh_guest 'command -v nft >/dev/null 2>&1'; then
	ok "firewall backend probe: nft"
	if [[ "$REQUIRE_LOG_PIPELINE" -eq 1 ]]; then
		run_required_log_pipeline nft
	else
		run_optional_log_pipeline nft
	fi
elif ssh_guest 'command -v iptables >/dev/null 2>&1'; then
	ok "firewall backend probe: iptables"
	if [[ "$REQUIRE_LOG_PIPELINE" -eq 1 ]]; then
		run_required_log_pipeline iptables
	else
		run_optional_log_pipeline iptables
	fi
else
	die "firewall backend probe: neither nft nor iptables found"
fi

echo "== smoke passed ==" >&2

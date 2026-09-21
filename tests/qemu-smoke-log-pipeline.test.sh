#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Deterministic host harness for qemu-smoke-fwlive.sh's required log mode.
# This does not claim a live QEMU/package-payload run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/qemu-smoke-fwlive.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() { echo "qemu smoke log pipeline test FAIL: $*" >&2; exit 1; }
ok() { echo "qemu smoke log pipeline test OK: $*"; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -u
cmd="${!#}"

if [[ "$cmd" == *"command -v nft"* ]]; then
	printf '%s\n' /usr/sbin/nft
	exit 0
fi
if [[ "${FWLIVE_STUB_RULE_FAIL:-0}" == 1 && "$cmd" == *"nft insert"* ]]; then
	echo 'stub: nft rule setup failed' >&2
	exit 42
fi
if [[ "${FWLIVE_STUB_TRAFFIC_FAIL:-0}" == 1 && "$cmd" == *"ping -c 3"* ]]; then
	echo 'stub: ping failed' >&2
	exit 43
fi
if [[ "$cmd" == *'DISTRIB_RELEASE'* ]]; then
	printf '%s\n' 24.10
elif [[ "$cmd" == 'uname -m' ]]; then
	printf '%s\n' x86_64
elif [[ "$cmd" == *'ls -1t /tmp/luci-indexcache'* ]]; then
	printf '%s\n' /tmp/luci-indexcache-test.json
elif [[ "$cmd" == *"cat '/usr/share/luci/menu.d/luci-app-fwlive.json'"* ]]; then
	printf '%s\n' '{"title":"Firewall Live View"," depends_on":{"acl":{"luci-app-fwlive":true}}}'
elif [[ "$cmd" == *'cat '*luci-indexcache* ]]; then
	printf '%s\n' 'Firewall Live View'
elif [[ "$cmd" == *'ubus call fwlive poll'* ]]; then
	if [[ "${FWLIVE_STUB_ROWS:-zero}" == rows ]]; then
		printf '%s\n' '{"log":[{"time":1717675742,"msg":"fw4: DROP IN=br-lan OUT= SRC=192.0.2.1 DST=192.0.2.2 PROTO=TCP DPT=443"}]}'
	else
		printf '%s\n' '{"log":[]}'
	fi
else
	:
fi
EOF
chmod 755 "$TMP/bin/ssh"

cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
has_headers=0
for arg in "$@"; do
	[[ "$arg" == '-D' ]] && has_headers=1
done
if [[ "$has_headers" -eq 1 ]]; then
	printf '%s\n' 'HTTP/1.1 302 Found'
fi
EOF
chmod 755 "$TMP/bin/curl"

cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$TMP/bin/sleep"

run_smoke() {
	local label="$1"; shift
	local output="$TMP/${label}.log"
	if PATH="$TMP/bin:$PATH" OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 \
		OWRT_HOSTFWD_HTTP=8080 FWLIVE_STUB_ROWS="${FWLIVE_STUB_ROWS:-zero}" \
		FWLIVE_STUB_RULE_FAIL="${FWLIVE_STUB_RULE_FAIL:-0}" \
		FWLIVE_STUB_TRAFFIC_FAIL="${FWLIVE_STUB_TRAFFIC_FAIL:-0}" \
		bash "$SCRIPT" "$@" >"$output" 2>&1; then
		return 0
	fi
	return 1
}

bash -n "$SCRIPT" || die 'qemu smoke script has invalid shell syntax'
"$SCRIPT" --help >/dev/null || die '--help failed'
grep -Fq -- '--require-log-pipeline' "$ROOT/scripts/lib/validate-matrix.sh" \
	|| die 'validation matrix does not require the log pipeline'
grep -Fq -- '--require-log-pipeline' "$ROOT/scripts/qemu-install-from-feed.sh" \
	|| die 'feed install smoke does not require the log pipeline'
grep -Fq -- '--require-log-pipeline' "$ROOT/scripts/qemu-smoke-matrix.sh" \
	|| die 'QEMU smoke matrix does not require the log pipeline'
ok 'mode and caller wiring present'

if run_smoke zero-rows --require-log-pipeline; then
	die 'required mode passed with zero parsed rows'
fi
grep -Fq 'firewall log pipeline produced zero parsed rows (nft)' "$TMP/zero-rows.log" \
	|| die 'zero-row failure did not preserve a useful backend diagnostic'
ok 'required mode rejects zero parsed rows'

if (FWLIVE_STUB_RULE_FAIL=1 FWLIVE_STUB_ROWS=rows; export FWLIVE_STUB_RULE_FAIL FWLIVE_STUB_ROWS; \
	run_smoke rule-failure --require-log-pipeline); then
		die 'required mode passed after nft setup failure'
	fi
grep -Fq 'firewall log rule setup failed (nft)' "$TMP/rule-failure.log" \
	|| die 'rule setup failure was not reported'
ok 'required mode rejects rule setup failure'


if (FWLIVE_STUB_TRAFFIC_FAIL=1 FWLIVE_STUB_ROWS=rows; export FWLIVE_STUB_TRAFFIC_FAIL FWLIVE_STUB_ROWS; \
	run_smoke traffic-failure --require-log-pipeline); then
		die 'required mode passed after traffic generation failure'
	fi
grep -Fq 'firewall traffic generation failed (nft)' "$TMP/traffic-failure.log" \
	|| die 'traffic failure was not reported'
ok 'required mode rejects traffic generation failure'

FWLIVE_STUB_ROWS=zero run_smoke best-effort-zero || die 'default best-effort mode stopped on zero rows'
grep -Fq 'smoke WARN: no parsed firewall rows yet' "$TMP/best-effort-zero.log" \
	|| die 'best-effort zero rows did not warn (wc -l empty JSON would look like one row)'
ok 'default mode remains best effort'

FWLIVE_STUB_ROWS=rows run_smoke required-rows --require-log-pipeline \
	|| die 'required mode rejected a parsed firewall row'
grep -Fq '1 parsed row(s)' "$TMP/required-rows.log" \
	|| die 'required mode did not report parsed row count'
ok 'required mode accepts parsed firewall rows'

echo 'qemu smoke log pipeline tests passed'

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Host stub for qemu-reset-wan-logging.sh. Does not claim a live QEMU run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/qemu-reset-wan-logging.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() { echo "qemu reset wan-logging test FAIL: $*" >&2; exit 1; }
ok() { echo "qemu reset wan-logging test OK: $*"; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -u
cmd="${!#}"
marker="${FWLIVE_STUB_RM_MARKER:-}"

if [[ "$cmd" == 'echo connected' ]]; then
	exit 0
fi
if [[ "$cmd" == 'test -x /usr/libexec/rpcd/fwlive' ]]; then
	[[ "${FWLIVE_STUB_INSTALLED:-1}" == 1 ]]
	exit $?
fi
if [[ "$cmd" == 'ubus call fwlive disable_wan_logging' ]]; then
	if [[ "${FWLIVE_STUB_DISABLE_OK:-1}" == 1 ]]; then
		printf '%s\n' '{"ok":true,"changed":true,"wan_zone":"wan"}'
	else
		printf '%s\n' '{"ok":false,"changed":false,"wan_zone":"wan","error":"firewall_changes_pending"}'
	fi
	exit 0
fi
if [[ "$cmd" == 'rm -f /etc/fwlive/wan-log-baseline' ]]; then
	[[ -n "$marker" ]] && printf 'rm\n' >>"$marker"
	exit 0
fi
if [[ "$cmd" == *'logging_status'* ]]; then
	printf '%s\n' '{"wan_zone":"wan","wan_log":false}'
	exit 0
fi
exit 0
EOF
chmod 755 "$TMP/bin/ssh"

run_reset() {
	local label="$1"
	PATH="$TMP/bin:$PATH" OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 \
		FWLIVE_STUB_INSTALLED="${FWLIVE_STUB_INSTALLED:-1}" \
		FWLIVE_STUB_DISABLE_OK="${FWLIVE_STUB_DISABLE_OK:-1}" \
		FWLIVE_STUB_RM_MARKER="$TMP/rm.${label}" \
		bash "$SCRIPT" >"$TMP/${label}.log" 2>&1
}

bash -n "$SCRIPT" || die 'reset script has invalid shell syntax'

FWLIVE_STUB_DISABLE_OK=0 run_reset refused && die 'reset succeeded on ok:false disable'
grep -Fq 'baseline preserved at /etc/fwlive/wan-log-baseline' "$TMP/refused.log" \
	|| die 'ok:false did not keep the baseline diagnostic'
[[ -e "$TMP/rm.refused" ]] && die 'ok:false deleted the baseline'
ok 'ok:false preserves baseline'

FWLIVE_STUB_DISABLE_OK=1 run_reset oktrue || die 'reset failed on ok:true disable'
[[ -e "$TMP/rm.oktrue" ]] || die 'ok:true did not remove the baseline'
ok 'ok:true removes baseline'

FWLIVE_STUB_INSTALLED=0 run_reset absent || die 'reset failed when fwlive is absent'
[[ -e "$TMP/rm.absent" ]] || die 'absent fwlive did not remove the baseline'
ok 'absent fwlive still removes baseline'

echo 'qemu reset wan-logging tests passed'

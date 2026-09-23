#!/usr/bin/env bash
# agent-build-and-deploy.sh is ipk-only (#434). Suffix is checked before
# existence so a missing .apk still points at qemu-install-fwlive.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/agent-build-and-deploy.sh"
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

out="$("$SCRIPT" --help)"
printf '%s\n' "$out" | grep -q 'ipk-only' \
	&& ok "usage mentions ipk-only" \
	|| bad "usage() must include the ipk-only note"

apk_err="$("$SCRIPT" --ipk /tmp/fwlive-missing.apk 2>&1)" && {
	bad "missing .apk must die"
	apk_err=""
} || true
printf '%s\n' "$apk_err" | grep -q 'qemu-install-fwlive.sh' \
	&& ok "missing .apk points at qemu-install-fwlive.sh" \
	|| bad "missing .apk should mention qemu-install-fwlive.sh (got: $apk_err)"
printf '%s\n' "$apk_err" | grep -q 'ipk not found' \
	&& bad "missing .apk must not die as ipk not found first" \
	|| ok "missing .apk does not use the existence message"

ipk_err="$("$SCRIPT" --ipk /tmp/fwlive-missing.ipk 2>&1)" && {
	bad "missing .ipk must die"
	ipk_err=""
} || true
printf '%s\n' "$ipk_err" | grep -q 'ipk not found' \
	&& ok "missing .ipk reports not found" \
	|| bad "missing .ipk should report ipk not found (got: $ipk_err)"

if [[ "$fail" -ne 0 ]]; then
	echo "FAIL: agent-build-and-deploy ipk-only guards" >&2
	exit 1
fi
echo "ok: agent-build-and-deploy ipk-only guards"

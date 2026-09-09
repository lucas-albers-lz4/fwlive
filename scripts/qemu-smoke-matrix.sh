#!/usr/bin/env bash
# Run the complete fwlive QEMU smoke against both lab architectures.
# Guests must already be running and have the package installed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_arch() {
	local label="$1" ssh_port="$2" http_port="$3"
	echo "== full smoke: ${label} ==" >&2
	OPENWRT_SSH_PORT="$ssh_port" OWRT_HOSTFWD_HTTP="$http_port" \
		"${ROOT}/scripts/qemu-smoke-fwlive.sh"
}

set +e
run_arch x86_64 "${FWLIVE_X86_SSH_PORT:-2222}" "${FWLIVE_X86_HTTP_PORT:-8080}"
x86_status=$?
run_arch armsr-armv8 "${FWLIVE_ARMSR_SSH_PORT:-2223}" "${FWLIVE_ARMSR_HTTP_PORT:-8081}"
armsr_status=$?
set -e

if (( x86_status != 0 || armsr_status != 0 )); then
	echo "== architecture smoke failed (x86_64=${x86_status}, armsr-armv8=${armsr_status}) ==" >&2
	exit 1
fi

echo "== both architecture smokes passed ==" >&2

#!/usr/bin/env bash
# Port validation and conflict-hint contract (#816 #809).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/qemu-lab-net.sh
source "${ROOT}/scripts/lib/qemu-lab-net.sh"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

qemu_lab_validate_port HTTP 8080 || fail "8080 must be valid"
qemu_lab_validate_port SSH 2222 || fail "2222 must be valid"
if qemu_lab_validate_port HTTP abc 2>/dev/null; then
	fail "non-numeric port must fail"
fi
if qemu_lab_validate_port HTTP 0 2>/dev/null; then
	fail "port 0 must fail"
fi
if qemu_lab_validate_port HTTP 65536 2>/dev/null; then
	fail "port 65536 must fail"
fi

hint="$(qemu_lab_port_owners_hint)"
[[ "$hint" == *"lab/compose.yml"* ]] || fail "hint must name lab/compose.yml"
[[ "$hint" == *"owrt-x64-exp"* ]] || fail "hint must name owrt-x64-exp"
[[ "$hint" == *"run-openwrt-x86-qemu.sh --stop"* ]] || fail "hint must name x86 --stop"
[[ "$hint" == *"run-openwrt-armsr-armv8-qemu.sh --stop"* ]] || fail "hint must name armsr --stop"
[[ "$hint" == *"lab/README.md"* ]] || fail "hint must point at lab/README.md"

grep -Fq 'qemu_lab_assert_host_port_free' "${ROOT}/scripts/run-openwrt-x86-qemu.sh" \
	|| fail "x86 runner must use qemu_lab_assert_host_port_free"
grep -Fq 'qemu_lab_assert_host_port_free' "${ROOT}/scripts/run-openwrt-armsr-armv8-qemu.sh" \
	|| fail "armsr runner must use qemu_lab_assert_host_port_free"

# ss parse error must fail closed (malformed port never treated as free).
if qemu_lab_assert_host_port_free abc HTTP 2>/dev/null; then
	fail "malformed port must not be treated as free"
fi

echo "qemu lab ports (#816 #809) passed"

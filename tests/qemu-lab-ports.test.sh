#!/usr/bin/env bash
# Port validation and conflict-hint contract (#816 #809 #988).
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
[[ "$hint" == *"run-openwrt-x86-qemu.sh --stop --force"* ]] || fail "hint must name x86 --stop --force"
[[ "$hint" == *"run-openwrt-armsr-armv8-qemu.sh --stop --force"* ]] || fail "hint must name armsr --stop --force"
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

OWRT_HOSTFWD_BIND="127.0.0.1"
got="$(qemu_lab_hostfwd_rule tcp 8080 80)"
[[ "$got" == "tcp:127.0.0.1:8080-:80" ]] || fail "IPv4 bind rule: $got"
OWRT_HOSTFWD_BIND=""
got="$(qemu_lab_hostfwd_rule tcp 8080 80)"
[[ "$got" == "tcp::8080-:80" ]] || fail "empty bind rule: $got"
for bad in '127.0.0.1,evil' '127.0.0.1:9' '127.0.0.1 ' '::1' '256.0.0.1' '1.2.3'; do
	OWRT_HOSTFWD_BIND="$bad"
	if qemu_lab_hostfwd_rule tcp 8080 80 >/dev/null 2>&1; then
		fail "bind must be rejected: $bad"
	fi
	if qemu_lab_hostfwd_pair 8080 2222 >/dev/null 2>&1; then
		fail "hostfwd pair must propagate a rejected bind: $bad"
	fi
	if qemu_lab_nic_user 8080 2222 >/dev/null 2>&1; then
		fail "x86 NIC wrapper must propagate a rejected bind: $bad"
	fi
	if qemu_lab_netdev_lan 8080 2222 >/dev/null 2>&1; then
		fail "armsr netdev wrapper must propagate a rejected bind: $bad"
	fi
done
OWRT_HOSTFWD_BIND=""

for runner in "$ROOT/scripts/run-openwrt-x86-qemu.sh" "$ROOT/scripts/run-openwrt-armsr-armv8-qemu.sh"; do
	if out="$(OWRT_HOSTFWD_BIND='1.2.3.4,evil' "$runner" 2>&1)"; then
		fail "runner must reject an invalid hostfwd bind before launch: $runner"
	else
		rc=$?
	fi
	[[ "$rc" -ne 0 ]] || fail "runner must exit non-zero for an invalid bind: $runner"
	[[ "$out" == *"OWRT_HOSTFWD_BIND must be an IPv4 address or empty"* ]] ||
		fail "runner must surface the bind validation error before other preflight: $runner ($out)"
	[[ "$out" != *"No disk image"* ]] ||
		fail "runner reached image preflight before rejecting its invalid bind: $runner"
done

echo "qemu lab hostfwd bind (#920 #988) passed"

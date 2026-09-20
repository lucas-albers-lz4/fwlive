#!/usr/bin/env bash
# Validate luci-app-fwlive for one OpenWrt version + QEMU architecture.
#
# Same flow as the original validate-openwrt-23.05.sh, parameterized.
#
#   ./scripts/validate-baseline.sh
#   ./scripts/validate-openwrt.sh --version 24.10
#   ./scripts/validate-openwrt.sh --version 23.05 --qemu-target armsr
#   ./scripts/validate-openwrt.sh --version 25.12 --skip-build
#
# Defaults: version=24.10, qemu-target=x86 (KVM), sdk-target=armsr-armv8
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/validate-matrix.sh
source "${ROOT}/scripts/lib/validate-matrix.sh"

VERSION="${OWRT_VALIDATE_VERSION:-24.10}"
# OWRT_VALIDATE_TARGET is legacy alias for qemu-target (23.05 wrapper era).
QEMU_TARGET="${OWRT_VALIDATE_QEMU_TARGET:-${OWRT_VALIDATE_TARGET:-x86}}"
SDK_TARGET="${OWRT_VALIDATE_SDK_TARGET:-armsr-armv8}"
SKIP_BUILD=0
SKIP_BASELINE=0

usage() {
	cat <<'EOF'
Usage: validate-openwrt.sh [options]

Options:
  --version VERSION     snapshot | 25.12 | 24.10 | 23.05 | full patch (default: 24.10)
  --qemu-target TARGET  x86 | armsr   (default: x86 — fast KVM lab)
  --sdk-target TARGET   armsr-armv8 | x86-64   (default: armsr-armv8)
  --skip-build          assume ipk already built for this version
  --skip-baseline       do not run validate-baseline.sh first

Environment:
  OWRT_VALIDATE_SSH_WAIT_X86=300      max seconds waiting for x86 SSH
  OWRT_VALIDATE_SSH_WAIT_ARMSR=1800   max seconds for armsr TCG boot

Examples:
  ./scripts/validate-openwrt.sh --version 25.12
  ./scripts/validate-openwrt.sh --version snapshot --qemu-target x86
  OWRT_VALIDATE_QEMU_TARGET=armsr ./scripts/validate-openwrt.sh --version 24.10
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) VERSION="${2:?}"; shift 2 ;;
		--qemu-target) QEMU_TARGET="${2:?}"; shift 2 ;;
		--sdk-target) SDK_TARGET="${2:?}"; shift 2 ;;
		--skip-build) SKIP_BUILD=1; shift ;;
		--skip-baseline) SKIP_BASELINE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown arg: $1" >&2; usage >&2; exit 1 ;;
	esac
done

sdk_matrix_validate_version "$VERSION"
sdk_matrix_validate_target "$SDK_TARGET"
validate_matrix_validate_qemu_target "$QEMU_TARGET"

if [[ "$SKIP_BASELINE" -eq 0 ]]; then
	"${ROOT}/scripts/validate-baseline.sh"
fi

validate_matrix_run_cell "$VERSION" "$QEMU_TARGET" "$SDK_TARGET" "$SKIP_BUILD"

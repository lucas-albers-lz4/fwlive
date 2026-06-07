#!/usr/bin/env bash
# Run validation across OpenWrt versions (and optionally all QEMU targets).
#
# Phased use (recommended):
#   1. ./scripts/validate-baseline.sh
#   2. ./scripts/validate-openwrt-all.sh build          # all SDK ipks, no QEMU
#   3. ./scripts/validate-openwrt-all.sh smoke-x86     # fast KVM smoke per version
#   4. ./scripts/validate-openwrt-all.sh smoke --version 24.10 --qemu-target armsr
#
#   ./scripts/validate-openwrt-all.sh list
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/validate-matrix.sh
source "${ROOT}/scripts/lib/validate-matrix.sh"

MODE="${1:-}"
shift || true

VERSION_FILTER=""
QEMU_FILTER=""
SDK_TARGET="${OWRT_VALIDATE_SDK_TARGET:-armsr-armv8}"
SKIP_BUILD=0

usage() {
	cat <<'EOF'
Usage: validate-openwrt-all.sh <command> [options]

Commands:
  list        Show validation matrix (versions × qemu targets)
  build       SDK build all versions (no QEMU) — ipk is _all arch
  build-full  SDK build all version × sdk-target cells (docker-sdk build-all)
  smoke-x86   End-to-end smoke on x86 KVM for each version (sequential)
  smoke       One cell: --version REQUIRED, optional --qemu-target

Options:
  --version VERSION       Filter to one OpenWrt version
  --qemu-target TARGET    x86 | armsr
  --sdk-target TARGET     armsr-armv8 | x86-64
  --skip-build            skip SDK compile in smoke modes

Run ./scripts/validate-baseline.sh before first smoke.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) VERSION_FILTER="${2:?}"; shift 2 ;;
		--qemu-target) QEMU_FILTER="${2:?}"; shift 2 ;;
		--sdk-target) SDK_TARGET="${2:?}"; shift 2 ;;
		--skip-build) SKIP_BUILD=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown arg: $1" >&2; usage >&2; exit 1 ;;
	esac
done

versions=("${SDK_MATRIX_VERSIONS[@]}")
if [[ -n "$VERSION_FILTER" ]]; then
	versions=("$VERSION_FILTER")
fi

case "$MODE" in
	list)
		echo "Validation matrix (OpenWrt version × QEMU lab target):" >&2
		printf '  %-10s %-8s  release patch\n' "version" "qemu" >&2
		local_v=""
		for local_v in "${versions[@]}"; do
			local_q=""
			for local_q in "${VALIDATE_MATRIX_QEMU_TARGETS[@]}"; do
				printf '  %-10s %-8s  %s\n' "$local_v" "$local_q" "$(validate_matrix_lab_slug "$local_v")"
			done
		done
		;;
	build)
		"${ROOT}/scripts/validate-baseline.sh"
		for local_v in "${versions[@]}"; do
			echo "→ build ${local_v} (${SDK_TARGET})" >&2
			validate_matrix_sdk_build "$SDK_TARGET" "$local_v"
		done
		echo "== build-all versions finished ==" >&2
		;;
	build-full)
		"${ROOT}/scripts/validate-baseline.sh"
		args=()
		[[ -n "$VERSION_FILTER" ]] && args+=(--version "$VERSION_FILTER")
		[[ -n "${OWRT_VALIDATE_SDK_TARGET:-}" ]] && args+=(--target "$SDK_TARGET")
		"${ROOT}/scripts/docker-sdk.sh" build-all "${args[@]}"
		;;
	smoke-x86)
		# x86 KVM guests need x86-64 packages (25.12+ apk); fall back to _all ipk when present.
		if [[ -z "${OWRT_VALIDATE_SDK_TARGET:-}" && "$SDK_TARGET" == "armsr-armv8" ]]; then
			SDK_TARGET="x86-64"
		fi
		# Snapshot downloads are minimal (no LuCI/uhttpd) — smoke pinned releases only.
		smoke_versions=()
		for local_v in "${versions[@]}"; do
			[[ "$local_v" == "snapshot" ]] && continue
			smoke_versions+=("$local_v")
		done
		[[ ${#smoke_versions[@]} -ge 1 ]] || { echo "no smokeable versions (snapshot is build-only)" >&2; exit 1; }
		"${ROOT}/scripts/validate-baseline.sh"
		for local_v in "${smoke_versions[@]}"; do
			"${ROOT}/scripts/validate-openwrt.sh" \
				--version "$local_v" \
				--qemu-target x86 \
				--sdk-target "$SDK_TARGET" \
				$([[ "$SKIP_BUILD" -eq 1 ]] && echo --skip-build) \
				--skip-baseline
		done
		echo "== smoke-x86 all versions passed ==" >&2
		;;
	smoke)
		[[ -n "$VERSION_FILTER" ]] || { echo "smoke requires --version" >&2; exit 1; }
		qemu="${QEMU_FILTER:-x86}"
		"${ROOT}/scripts/validate-openwrt.sh" \
			--version "$VERSION_FILTER" \
			--qemu-target "$qemu" \
			--sdk-target "$SDK_TARGET" \
			$([[ "$SKIP_BUILD" -eq 1 ]] && echo --skip-build)
		;;
	''|-h|--help|help)
		usage
		;;
	*)
		echo "unknown command: $MODE" >&2
		usage >&2
		exit 1
		;;
esac

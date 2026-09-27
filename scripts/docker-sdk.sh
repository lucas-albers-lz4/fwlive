#!/usr/bin/env bash
# Unified OpenWrt SDK driver for multi-version / multi-target builds.
#
# Examples:
#   ./scripts/docker-sdk.sh list
#   ./scripts/docker-sdk.sh setup --target armsr-armv8 --version 24.10
#   ./scripts/docker-sdk.sh make --target x86-64 --version snapshot
#   ./scripts/docker-sdk.sh copy-out --target armsr-armv8 --version 23.05
#   ./scripts/docker-sdk.sh build --target x86-64 --version 24.10
#   ./scripts/docker-sdk.sh build-all
#   ./scripts/docker-sdk.sh build-all --target x86-64
#
# Defaults: --target armsr-armv8 --version snapshot (same as legacy sdk-official).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sdk-matrix.sh
source "$ROOT/scripts/lib/sdk-matrix.sh"

usage() {
	cat <<'EOF'
Usage: docker-sdk.sh <command> [options] [make-args...]

Commands:
  list       Show supported target × version combinations
  list-cells Show target/version cells selected by --target/--version
  setup      Configure feeds + defconfig (once per SDK volume)
  make       Compile luci-app-fwlive
  copy-out   Copy packages to out/<arch>/<version>/
  build      setup (if needed) + make + copy-out
  build-all  Run build for every matrix cell (or filter with --target/--version)

Options:
  --target TARGET    armsr-armv8 | x86-64   (default: armsr-armv8)
  --version VERSION  snapshot | 25.12 | 24.10 | 23.05   (default: snapshot)

Make parallelism (host CPUs):
  Default -j8 on 8+ core hosts (nproc capped at 16). Override:
    OWRT_MAKE_JOBS=16 ./scripts/docker-sdk.sh make
    ./scripts/docker-sdk.sh make -j 4

Legacy wrappers (unchanged defaults):
  docker-sdk-official-setup-feeds.sh  →  docker-sdk.sh setup
  docker-sdk-official-make.sh         →  docker-sdk.sh make
  docker-sdk-official-copy-out.sh     →  docker-sdk.sh copy-out
EOF
}

CMD="${1:-}"
shift || true

TARGET="${OWRT_SDK_TARGET:-armsr-armv8}"
VERSION="${OWRT_SDK_VERSION:-snapshot}"
SEEN_TARGET=0
SEEN_VERSION=0
[[ -n "${OWRT_SDK_TARGET:-}" ]] && SEEN_TARGET=1
[[ -n "${OWRT_SDK_VERSION:-}" ]] && SEEN_VERSION=1
MAKE_ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--target)
			TARGET="${2:?}"
			SEEN_TARGET=1
			shift 2
			;;
		--version)
			VERSION="${2:?}"
			SEEN_VERSION=1
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			MAKE_ARGS+=("$1")
			shift
			;;
	esac
done

SELECTED_TARGETS=("${SDK_MATRIX_TARGETS[@]}")
SELECTED_VERSIONS=("${SDK_MATRIX_VERSIONS[@]}")
if [[ "$SEEN_TARGET" -eq 1 ]]; then
	SELECTED_TARGETS=("$TARGET")
fi
if [[ "$SEEN_VERSION" -eq 1 ]]; then
	SELECTED_VERSIONS=("$VERSION")
fi

run_one() {
	local t="$1" v="$2"
	sdk_matrix_validate_target "$t"
	sdk_matrix_validate_version "$v"
	sdk_matrix_pull_and_pin "$t" "$v" >/dev/null
	echo "→ ${SDK_MATRIX_IMAGE} (volume: ${SDK_MATRIX_VOLUME})" >&2
}

case "$CMD" in
	list)
		sdk_matrix_list
		;;
	list-cells)
		for t in "${SELECTED_TARGETS[@]}"; do
			sdk_matrix_validate_target "$t"
		done
		for v in "${SELECTED_VERSIONS[@]}"; do
			sdk_matrix_validate_version "$v"
		done
		for t in "${SELECTED_TARGETS[@]}"; do
			for v in "${SELECTED_VERSIONS[@]}"; do
				echo "$t $v"
			done
		done
		;;
	setup)
		run_one "$TARGET" "$VERSION"
		sdk_matrix_feeds_setup
		echo "Feeds ready. Build: ./scripts/docker-sdk.sh make --target $TARGET --version $VERSION" >&2
		;;
	make)
		run_one "$TARGET" "$VERSION"
		sdk_matrix_make "${MAKE_ARGS[@]}"
		echo "Copy: ./scripts/docker-sdk.sh copy-out --target $TARGET --version $VERSION" >&2
		;;
	copy-out)
		run_one "$TARGET" "$VERSION"
		sdk_matrix_copy_out
		;;
	build)
		run_one "$TARGET" "$VERSION"
		if ! sdk_matrix_feeds_ready; then
			sdk_matrix_feeds_setup
		fi
		sdk_matrix_make "${MAKE_ARGS[@]}"
		sdk_matrix_copy_out
		;;
	build-all)
		for t in "${SELECTED_TARGETS[@]}"; do
			for v in "${SELECTED_VERSIONS[@]}"; do
				run_one "$t" "$v"
				if ! sdk_matrix_feeds_ready; then
					sdk_matrix_feeds_setup
				fi
				sdk_matrix_make "${MAKE_ARGS[@]}"
				sdk_matrix_copy_out
				echo >&2
			done
		done
		echo "All requested matrix builds finished under ${ROOT}/out/" >&2
		;;
	'' | -h | --help | help)
		usage
		exit 0
		;;
	*)
		echo "unknown command: $CMD" >&2
		usage >&2
		exit 1
		;;
esac

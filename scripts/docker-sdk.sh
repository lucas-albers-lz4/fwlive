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
  setup      Configure feeds + defconfig (once per SDK volume)
  make       Compile luci-app-fwlive
  copy-out   Copy packages to out/<arch>/<version>/
  build      setup (if needed) + make + copy-out
  build-all  Run build for every matrix cell (or filter with --target/--version)

Options:
  --target TARGET    armsr-armv8 | x86-64   (default: armsr-armv8)
  --version VERSION  snapshot | 25.12 | 24.10 | 23.05 | 22.03 | 21.02   (default: snapshot)

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
MAKE_ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--target)
			TARGET="${2:?}"
			shift 2
			;;
		--version)
			VERSION="${2:?}"
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

run_one() {
	local t="$1" v="$2"
	sdk_matrix_validate_target "$t"
	sdk_matrix_validate_version "$v"
	sdk_matrix_resolve "$t" "$v"
	echo "→ ${SDK_MATRIX_IMAGE} (volume: ${SDK_MATRIX_VOLUME})" >&2
}

case "$CMD" in
	list)
		sdk_matrix_list
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
		sdk_matrix_pull
		if ! sdk_matrix_feeds_ready; then
			sdk_matrix_feeds_setup
		fi
		sdk_matrix_make "${MAKE_ARGS[@]}"
		sdk_matrix_copy_out
		;;
	build-all)
		targets=("${SDK_MATRIX_TARGETS[@]}")
		versions=("${SDK_MATRIX_VERSIONS[@]}")
		if [[ "$TARGET" != "armsr-armv8" || -n "${OWRT_SDK_TARGET:-}" ]]; then
			targets=("$TARGET")
		fi
		if [[ "$VERSION" != "snapshot" || -n "${OWRT_SDK_VERSION:-}" ]]; then
			versions=("$VERSION")
		fi
		for t in "${targets[@]}"; do
			for v in "${versions[@]}"; do
				run_one "$t" "$v"
				sdk_matrix_pull
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

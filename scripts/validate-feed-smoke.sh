#!/usr/bin/env bash
# End-to-end: boot QEMU x86 guest, install luci-app-fwlive from live feed URL, smoke test.
#
#   FWLIVE_FEED_BASE_URL=https://lucas-albers-lz4.github.io/fwlive-packages \
#     ./scripts/validate-feed-smoke.sh --version 24.10
#
# Used by publish-packages CI after GitHub Pages deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/validate-matrix.sh
source "${ROOT}/scripts/lib/validate-matrix.sh"

VERSION="${OWRT_VALIDATE_VERSION:-24.10}"
QEMU_TARGET="${OWRT_VALIDATE_QEMU_TARGET:-x86}"
FEED_URL="${FWLIVE_FEED_BASE_URL:?set FWLIVE_FEED_BASE_URL}"

usage() {
	cat <<EOF
Usage: validate-feed-smoke.sh [options]

Options:
  --version VERSION   21.02 | 23.05 | 24.10 | 25.12 (default: 24.10)
  --feed-url URL      override FWLIVE_FEED_BASE_URL
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) VERSION="${2:?}"; shift 2 ;;
		--feed-url) FEED_URL="${2:?}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "unknown arg: $1" >&2; usage >&2; exit 1 ;;
	esac
done

sdk_matrix_validate_version "$VERSION"
validate_matrix_validate_qemu_target "$QEMU_TARGET"

lab_slug="$(validate_matrix_lab_slug "$VERSION")"
img="$(validate_matrix_image_path "$QEMU_TARGET" "$VERSION")"

echo "== feed smoke: ${VERSION} feed=${FEED_URL} ==" >&2

if [[ ! -f "$img" ]]; then
	validate_matrix_download_image "$QEMU_TARGET" "$VERSION"
fi
img="$(validate_matrix_image_path "$QEMU_TARGET" "$VERSION")"
[[ -f "$img" ]] || validate_matrix_die "missing image: $img"

validate_matrix_prepare_image "$img"
validate_matrix_start_qemu "$QEMU_TARGET" "$VERSION"
validate_matrix_wait_ssh "$QEMU_TARGET"

export FWLIVE_FEED_BASE_URL="$FEED_URL"
"${ROOT}/scripts/qemu-install-from-feed.sh" --version "$VERSION"

validate_matrix_stop_qemu
echo "== feed smoke passed: ${VERSION} ==" >&2

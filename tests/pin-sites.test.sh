#!/usr/bin/env bash
# Keep the per-patch index helper and artifact-search fallback in sync with the
# release labels defined by sdk-matrix.sh (#891).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/lib/sdk-matrix.sh
source "$ROOT/scripts/lib/sdk-matrix.sh"

mapfile -t labels < <(sdk_matrix_release_version_labels | sort)
if [[ ${#labels[@]} -eq 0 ]]; then
	echo "no release version labels found" >&2
	exit 1
fi

index_script_block="$(sed -n '/^feed_publish_ipkg_index_script() {/,/^}/p' \
	"$ROOT/scripts/lib/feed-publish.sh")"
if [[ -z "$index_script_block" ]]; then
	echo "could not find feed_publish_ipkg_index_script" >&2
	exit 1
fi

artifact_fallback_line="$(sed -n '/^[[:space:]]*for ver in /,/; do/p' \
	"$ROOT/scripts/qemu-install-fwlive.sh")"
if [[ -z "$artifact_fallback_line" ]]; then
	echo "could not find qemu-install-fwlive.sh artifact-search fallback" >&2
	exit 1
fi
fallback_versions="${artifact_fallback_line#*for ver in }"
fallback_versions="${fallback_versions%%; do*}"
read -r -a fallback_labels <<<"$fallback_versions"

has_exact_label() {
	local wanted="$1" candidate
	shift
	for candidate in "$@"; do
		[[ "$candidate" == "$wanted" ]] && return 0
	done
	return 1
}

if has_exact_label 24.10.8 24.10.8.1; then
	echo "artifact fallback label check accepted a partial version token" >&2
	exit 1
fi

for label in "${labels[@]}"; do
	label_pattern="${label//./\\.}"
	case_row="$(printf '%s\n' "$index_script_block" | grep -E \
		"^[[:space:]]*${label_pattern}\\) sha='[0-9a-f]{40}'; expected_hash='[0-9a-f]{64}' ;;$" || true)"
	if [[ -z "$case_row" ]]; then
		echo "ipkg-make-index.sh case pin missing or malformed for release label: $label" >&2
		exit 1
	fi
	if ! has_exact_label "$label" "${fallback_labels[@]}"; then
		echo "qemu-install-fwlive.sh artifact-search fallback missing release label: $label" >&2
		exit 1
	fi
done

echo "release pin-site parity test passed"

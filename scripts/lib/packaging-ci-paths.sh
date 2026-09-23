#!/usr/bin/env bash
# Decide whether test-ipk-payload must run the SDK matrix (#557).
# Sourced by scripts/ci-packaging-paths.sh and host tests. Do not execute directly.

packaging_ci_sha_usable() {
	local sha="${1:-}"
	[[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
	[[ "$sha" =~ ^[0]{40}$ ]] && return 1
	return 0
}

packaging_ci_path_matches() {
	local path="${1#./}"
	case "$path" in
		openwrt-feed | openwrt-feed/*) return 0 ;;
		scripts/feeds.lock | scripts/feeds.lock/*) return 0 ;;
		scripts/lib/feeds-lock.sh) return 0 ;;
		scripts/lib/sdk-matrix.sh) return 0 ;;
		scripts/lib/packaging-ci-paths.sh) return 0 ;;
		scripts/docker-sdk.sh) return 0 ;;
		scripts/ci-packaging-paths.sh) return 0 ;;
		docker-compose.yml) return 0 ;;
		tests/fwlive-package-payload.test.sh) return 0 ;;
		tests/fwlive-package-lifecycle.test.sh) return 0 ;;
		.github/workflows/fwlive-test.yml) return 0 ;;
	esac
	return 1
}

# Read repo-relative paths from stdin. Return 0 if any path requires the matrix.
packaging_ci_paths_need_matrix() {
	local path
	while IFS= read -r path || [[ -n "$path" ]]; do
		[[ -z "$path" ]] && continue
		if packaging_ci_path_matches "$path"; then
			echo "packaging-ci-paths: $path requires SDK matrix" >&2
			return 0
		fi
	done
	return 1
}

packaging_ci_ensure_sha() {
	local sha="${1:-}"
	if git cat-file -e "${sha}^{commit}" 2>/dev/null; then
		return 0
	fi
	if GIT_TERMINAL_PROMPT=0 git fetch --depth=1 origin "$sha"; then
		return 0
	fi
	return 1
}

packaging_ci_emit() {
	local run_matrix="$1"
	local reason="$2"
	echo "packaging-ci-paths: ${reason}" >&2
	echo "run_matrix=${run_matrix}"
}

# Env: PACKAGING_CI_BASE_SHA, PACKAGING_CI_HEAD_SHA (40-hex; HEAD allowed in tests).
# Always prints run_matrix=true|false and exits 0 unless the shell itself errors.
packaging_ci_decide() {
	local base="${PACKAGING_CI_BASE_SHA:-}"
	local head="${PACKAGING_CI_HEAD_SHA:-}"
	local diff

	if ! packaging_ci_sha_usable "$base"; then
		packaging_ci_emit true "fail-closed (unusable base SHA); running matrix"
		return 0
	fi
	if [[ "$head" != HEAD ]] && ! packaging_ci_sha_usable "$head"; then
		packaging_ci_emit true "fail-closed (unusable head SHA); running matrix"
		return 0
	fi

	if ! packaging_ci_ensure_sha "$base"; then
		packaging_ci_emit true "fail-closed (cannot fetch base); running matrix"
		return 0
	fi
	if [[ "$head" != HEAD ]] && ! packaging_ci_ensure_sha "$head"; then
		packaging_ci_emit true "fail-closed (cannot fetch head); running matrix"
		return 0
	fi

	if ! diff="$(git diff --name-only "$base" "$head")"; then
		packaging_ci_emit true "fail-closed (git diff failed); running matrix"
		return 0
	fi

	if printf '%s\n' "$diff" | packaging_ci_paths_need_matrix; then
		packaging_ci_emit true "packaging path changed; running matrix"
		return 0
	fi

	packaging_ci_emit false "no packaging paths in diff; skipping SDK matrix"
}

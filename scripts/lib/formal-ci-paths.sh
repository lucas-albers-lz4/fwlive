#!/usr/bin/env bash
# Decide whether the always-reporting formal-tlc job must run TLC.
# Sourced by scripts/ci-formal-paths.sh and host tests; do not execute directly.

formal_ci_sha_usable() {
	local sha="${1:-}"
	[[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
	[[ "$sha" =~ ^[0]{40}$ ]] && return 1
	return 0
}

# Print one of: relevant, unrelated, unclassified.
# New paths default to unclassified so a missed classification runs TLC.
formal_ci_classify_path() {
	local path="${1#./}"
	case "$path" in
		formal | formal/*) printf 'relevant\n' ;;
		package.json | package-lock.json) printf 'relevant\n' ;;
		scripts/formal-* | scripts/lib/formal-* | scripts/ci-formal-paths.sh | scripts/fwlive-test.sh) printf 'relevant\n' ;;
		tests/*formal* | tests/*tlc* | tests/*model* | tests/*rollback* | \
		tests/*hostname* | tests/*poll* | tests/*adaptive* | tests/*logging* | tests/*quint* | \
			tests/mutate-wan-log-noop-generation.py) printf 'relevant\n' ;;
		.github/workflows/formal-tlc.yml | .github/workflows/formal-quint.yml) printf 'relevant\n' ;;
		openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh | \
			openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-adaptive-cap.sh | \
			openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js | \
			openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/hostname.js | \
			openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/poll-coordinator.js) printf 'relevant\n' ;;

		# Code can become modeled as fidelity maps grow. Keep all shipped
		# resource/helper code and core code conservative instead of pinning
		# an unrelated-code allowlist that could silently become stale.
		openwrt-feed/luci-app-fwlive/htdocs/* | \
			openwrt-feed/luci-app-fwlive/root/* | core/* | core) printf 'relevant\n' ;;
		openwrt-feed/luci-app-fwlive/Makefile | openwrt-feed/luci-app-fwlive/README.md | \
			openwrt-feed/luci-app-fwlive/po/*) printf 'unrelated\n' ;;

		# These repository areas have no source mapped by the current TLC models.
		# Keep known documentation/assets explicit; do not use broad script/test
		# globs here because a new modeled helper or test must fail closed.
		CHANGELOG.md | README.md | LICENSE | ATTRIBUTION.md) printf 'unrelated\n' ;;
		docs/* | docs) printf 'unrelated\n' ;;
		*.md) printf 'unrelated\n' ;;
		tests/fwlive-parser.test.js | scripts/embed-fwlive-css.js) printf 'unrelated\n' ;;
		*) printf 'unclassified\n' ;;
	esac
}

formal_ci_ensure_sha() {
	local sha="${1:-}"
	if git cat-file -e "${sha}^{commit}" 2>/dev/null; then
		return 0
	fi
	if GIT_TERMINAL_PROMPT=0 git fetch --quiet --depth=1 origin "$sha"; then
		return 0
	fi
	return 1
}

formal_ci_emit() {
	local run_formal="$1"
	local reason="$2"
	echo "formal-ci-paths: $reason" >&2
	echo "run_formal=$run_formal"
}

# Env: FORMAL_CI_BASE_SHA, FORMAL_CI_HEAD_SHA (40-hex; HEAD allowed in tests).
# Always emits run_formal=true|false. Unknown, empty, or failed diffs run TLC.
formal_ci_decide() {
	local base="${FORMAL_CI_BASE_SHA:-}"
	local head="${FORMAL_CI_HEAD_SHA:-}"
	local diff_file path class changed=0 unclassified=0 relevant=0

	if ! formal_ci_sha_usable "$base"; then
		formal_ci_emit true "fail-closed (unusable base SHA); running checks"
		return 0
	fi
	if [[ "$head" != HEAD ]] && ! formal_ci_sha_usable "$head"; then
		formal_ci_emit true "fail-closed (unusable head SHA); running checks"
		return 0
	fi
	if ! formal_ci_ensure_sha "$base"; then
		formal_ci_emit true "fail-closed (cannot fetch base); running checks"
		return 0
	fi
	if [[ "$head" != HEAD ]] && ! formal_ci_ensure_sha "$head"; then
		formal_ci_emit true "fail-closed (cannot fetch head); running checks"
		return 0
	fi

	# --no-renames keeps the old pathname visible when a modeled file moves out.
	# -z preserves unusual pathnames without shell quoting or newline ambiguity.
	diff_file="$(mktemp)" || {
		formal_ci_emit true "fail-closed (cannot create diff file); running checks"
		return 0
	}
	if ! git diff --no-renames -z --name-only "$base" "$head" >"$diff_file"; then
		rm -f "$diff_file"
		formal_ci_emit true "fail-closed (git diff failed); running checks"
		return 0
	fi

	while IFS= read -r -d '' path || [[ -n "$path" ]]; do
		[[ -z "$path" ]] && continue
		changed=$((changed + 1))
		class="$(formal_ci_classify_path "$path")"
		case "$class" in
			relevant)
				relevant=$((relevant + 1))
				echo "formal-ci-paths: relevant path: $path" >&2
				;;
			unrelated) ;;
			*)
				unclassified=$((unclassified + 1))
				echo "formal-ci-paths: unclassified path runs checks: $path" >&2
				;;
		esac
	done <"$diff_file"
	rm -f "$diff_file"

	if [[ "$changed" -eq 0 ]]; then
		formal_ci_emit true "fail-closed (empty or invalid path diff); running checks"
	elif [[ "$relevant" -gt 0 ]]; then
		formal_ci_emit true "modeled path changed; running checks"
	elif [[ "$unclassified" -gt 0 ]]; then
		formal_ci_emit true "unclassified path changed; running checks"
	else
		formal_ci_emit false "all changed paths are known unrelated; skipping TLC"
	fi
}

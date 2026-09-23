#!/usr/bin/env bash
# SPDX header + .pot template fail-closed gates for luci-app-fwlive (#291 / #444 / #445).
# Sourced by scripts/fwlive-test.sh and host tests. Do not execute directly.
#
# luci.mk installs everything under htdocs/; walk that tree with the same skip
# rule as root/ (*.md docs, *.json LuCI ACL/menu — must stay strict JSON).

fwlive_spdx_skip_file() {
	case "$1" in
		*.md | *.json) return 0 ;;
		*) return 1 ;;
	esac
}

# Print newline-delimited shipped paths under $1 (Makefile + root/ + htdocs/).
fwlive_spdx_list_shipped() {
	local pkg="$1"
	local f
	[[ -f "$pkg/Makefile" ]] && printf '%s\n' "$pkg/Makefile"
	if [[ -d "$pkg/root" ]]; then
		while IFS= read -r -d '' f; do
			fwlive_spdx_skip_file "$f" && continue
			printf '%s\n' "$f"
		done < <(find "$pkg/root" -type f -print0)
	fi
	if [[ -d "$pkg/htdocs" ]]; then
		while IFS= read -r -d '' f; do
			fwlive_spdx_skip_file "$f" && continue
			printf '%s\n' "$f"
		done < <(find "$pkg/htdocs" -type f -print0)
	fi
}

fwlive_spdx_file_has_header() {
	local f="$1"
	grep -qE \
		'^[[:space:]]*(#|/\*)[[:space:]]*SPDX-License-Identifier:[[:space:]]+[^[:space:]]+' \
		<<<"$(sed -n '1,6p' "$f")"
}

# Check comment-form SPDX headers on shipped files under package path $1.
fwlive_spdx_check_pkg() {
	local pkg="$1"
	local f
	local spdx_fail=0
	local -a files=()

	if [[ ! -f "$pkg/Makefile" || ! -d "$pkg/root" || ! -d "$pkg/htdocs" ]]; then
		echo "FAIL: luci-app-fwlive shipped tree incomplete under $pkg" >&2
		return 1
	fi

	mapfile -t files < <(fwlive_spdx_list_shipped "$pkg")
	if [[ "${#files[@]}" -lt 2 ]]; then
		echo "FAIL: SPDX walk found no shipped files under $pkg" >&2
		return 1
	fi
	for f in "${files[@]}"; do
		[[ -f "$f" ]] || { echo "FAIL: expected shipped file missing: $f" >&2; spdx_fail=1; continue; }
		if ! fwlive_spdx_file_has_header "$f"; then
			echo "FAIL: missing SPDX-License-Identifier header: $f" >&2
			spdx_fail=1
		fi
	done
	if [[ "$spdx_fail" -ne 0 ]]; then
		echo "FAIL: add SPDX-License-Identifier to shipped files (#291 C2)" >&2
		return 1
	fi
	return 0
}

# .pot must exist, be non-empty, and have no absolute #: refs (package path $1).
fwlive_pot_check_pkg() {
	local pkg="$1"
	local pot="$pkg/po/templates/luci-app-fwlive.pot"

	if [[ ! -f "$pot" || ! -r "$pot" ]]; then
		echo "FAIL: missing or unreadable .pot template: $pot" >&2
		return 1
	fi
	if [[ ! -s "$pot" ]]; then
		echo "FAIL: empty .pot template: $pot" >&2
		return 1
	fi
	if grep -E '^#: /' "$pot" >/dev/null; then
		echo "FAIL: absolute #: refs in $pot — run ./scripts/normalize-pot-paths.sh" >&2
		grep -E '^#: /' "$pot" | head -5 >&2
		return 1
	fi
	return 0
}

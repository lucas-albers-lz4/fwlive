#!/usr/bin/env bash
# Run shellcheck and a tab-indent gate on shipped rpcd/libexec shell (#86, #290 L7, #580).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBEXEC="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec"
BASELINE="$ROOT/scripts/shellcheck-baseline.txt"

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "Install shellcheck (e.g. apt install shellcheck) to run this gate." >&2
	exit 1
fi

# Curated exclusions: SC ids from baseline with a "# reason" annotation.
# Empty baseline → no --exclude (fail closed on any new warning).
EXCLUDE_ARGS=()
if [[ -f "$BASELINE" ]]; then
	SC_IDS=()
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${line//[[:space:]]/}" ]] && continue
		if [[ "$line" =~ ^(SC[0-9]+) ]]; then
			id="${BASH_REMATCH[1]}"
			reason="${line#*#}"
			if [[ "$line" != *#* || -z "${reason//[[:space:]]/}" ]]; then
				echo "FAIL: shellcheck-baseline entry missing # reason: $line" >&2
				exit 1
			fi
			SC_IDS+=("$id")
		fi
	done < "$BASELINE"
	if [[ ${#SC_IDS[@]} -gt 0 ]]; then
		# Unique sorted ids for --exclude=A,B,C
		mapfile -t SC_IDS < <(printf '%s\n' "${SC_IDS[@]}" | sort -u)
		EXCLUDE_ARGS=(--exclude="$(IFS=,; echo "${SC_IDS[*]}")")
	fi
fi

# Enumerate by discovery, not a fixed list, so a newly added script cannot
# silently escape this gate. The shipped rpcd entrypoint `rpcd/fwlive` has no
# extension, so match *.sh OR that exact name. Do not use -x: sourced paths
# are runtime-resolved ($FILTER_DIR / $LOGGING_SH).
# One NUL manifest feeds both the indent gate and ShellCheck (#580).
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
find "$LIBEXEC" -type f \( -name '*.sh' -o -name 'fwlive' \) -print0 >"$manifest"

# Physical-line tab gate: indent prefix starts with a space (`/^ /`).
# Space-only lines and space-leading heredoc text fail; empty / tab-only /
# tab-then-alignment-spaces pass. Not a shell parser.
xargs -0 -r awk '
	/^ / {
		printf "FAIL: space indent: %s:%d\n", FILENAME, FNR > "/dev/stderr"
		bad = 1
	}
	END { exit bad + 0 }
' <"$manifest"

# --severity=warning: style-only nits stay non-gating; warnings+ fail the build.
xargs -0 -r shellcheck -s sh --severity=warning "${EXCLUDE_ARGS[@]}" <"$manifest"

echo "fwlive shellcheck OK (severity=warning; baseline=$(basename "$BASELINE"))" >&2

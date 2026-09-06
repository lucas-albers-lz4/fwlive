#!/usr/bin/env bash
# Run shellcheck on shipped rpcd/libexec shell scripts (#86, #290 L7).
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
	mapfile -t SC_IDS < <(
		awk '
			/^[[:space:]]*#/ { next }
			/^[[:space:]]*$/ { next }
			match($0, /^SC[0-9]+/) {
				id = substr($0, RSTART, RLENGTH)
				if ($0 !~ /#/) {
					print "FAIL: shellcheck-baseline entry missing # reason: " $0 > "/dev/stderr"
					exit 2
				}
				print id
			}
		' "$BASELINE" | sort -u
	)
	if [[ ${#SC_IDS[@]} -gt 0 ]]; then
		EXCLUDE_ARGS=(--exclude="$(IFS=,; echo "${SC_IDS[*]}")")
	fi
fi

# Enumerate by discovery, not a fixed list, so a newly added script cannot
# silently escape this gate. The shipped rpcd entrypoint `rpcd/fwlive` has no
# extension, so match *.sh OR that exact name. Do not use -x: sourced paths
# are runtime-resolved ($FILTER_DIR / $LOGGING_SH).
# --severity=warning: style-only nits stay non-gating; warnings+ fail the build.
find "$LIBEXEC" -type f \( -name '*.sh' -o -name 'fwlive' \) -print0 \
	| xargs -0 -r shellcheck -s sh --severity=warning "${EXCLUDE_ARGS[@]}"

echo "fwlive shellcheck OK (severity=warning; baseline=$(basename "$BASELINE"))" >&2

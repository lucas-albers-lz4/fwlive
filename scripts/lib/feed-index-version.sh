#!/usr/bin/env bash
# Extract luci-app-fwlive Version / pkgver from a published feed index.
# Canonical source is the index the guest will use (#421), not ${tag#v} or
# the Makefile. Compare exact published forms (include -r1).
#
# Host/CI only — Bash required. Source from tests; do not execute directly.
set -euo pipefail

# shellcheck source=sdk-apk.sh
source "$(dirname "${BASH_SOURCE[0]}")/sdk-apk.sh"

FEED_INDEX_PKG=luci-app-fwlive

# Exact string compare of published forms. Empty values fail closed.
feed_index_versions_match() {
	local got="${1:-}" want="${2:-}"
	if [[ -z "$got" || -z "$want" ]]; then
		echo "feed-index: empty version form (got='$got' want='$want')" >&2
		return 1
	fi
	if [[ "$got" != "$want" ]]; then
		echo "feed-index: version mismatch: got '$got' want '$want'" >&2
		return 1
	fi
	return 0
}

# Usage: feed_index_opkg_version Packages|Packages.gz
feed_index_opkg_version() {
	local src="${1:-}" text got
	[[ -n "$src" && -f "$src" ]] || {
		echo "feed-index: Packages not found: ${src:-}" >&2
		return 1
	}
	if [[ "$src" == *.gz ]]; then
		text="$(gzip -dc -- "$src")" || {
			echo "feed-index: failed to decompress $src" >&2
			return 1
		}
	else
		text="$(cat -- "$src")" || {
			echo "feed-index: failed to read $src" >&2
			return 1
		}
	fi
	[[ -n "$text" ]] || {
		echo "feed-index: empty Packages: $src" >&2
		return 1
	}
	got="$(awk -v want="$FEED_INDEX_PKG" '
		BEGIN { RS = ""; FS = "\n"; found = 0; got = "" }
		{
			name = ""
			ver = ""
			for (i = 1; i <= NF; i++) {
				line = $i
				sub(/\r$/, "", line)
				if (line ~ /^Package:[[:space:]]*/) {
					name = line
					sub(/^Package:[[:space:]]*/, "", name)
				} else if (line ~ /^Version:[[:space:]]*/) {
					ver = line
					sub(/^Version:[[:space:]]*/, "", ver)
				}
			}
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", ver)
			if (name == want) {
				found = 1
				got = ver
			}
		}
		END {
			if (!found || got == "")
				exit 1
			print got
		}
	' <<<"$text")" || {
		echo "feed-index: $FEED_INDEX_PKG missing or empty Version in $src" >&2
		return 1
	}
	[[ -n "$got" ]] || {
		echo "feed-index: empty Version for $FEED_INDEX_PKG in $src" >&2
		return 1
	}
	printf '%s\n' "$got"
}

# Usage: feed_index_apk_pkgver packages.adb
# Dumps via sdk_apk_adbdump (pinned SDK apk). Never host apk.
feed_index_apk_pkgver() {
	local src="${1:-}" dump
	[[ -n "$src" && -f "$src" ]] || {
		echo "feed-index: packages.adb not found: ${src:-}" >&2
		return 1
	}
	command -v python3 >/dev/null 2>&1 || {
		echo "feed-index: python3 is required to parse apk adbdump JSON" >&2
		return 1
	}
	dump="$(sdk_apk_adbdump --format json "$src")" || {
		echo "feed-index: sdk_apk_adbdump failed for $src" >&2
		return 1
	}
	[[ -n "$dump" ]] || {
		echo "feed-index: empty apk adbdump for $src" >&2
		return 1
	}
	printf '%s' "$dump" | python3 -c '
import json, sys
want = sys.argv[1]
try:
    data = json.load(sys.stdin)
except (OSError, json.JSONDecodeError) as exc:
    sys.stderr.write("feed-index: invalid apk adbdump JSON: %s\n" % exc)
    sys.exit(1)
pkgs = []
if isinstance(data, dict) and "packages" in data:
    data = data["packages"]
if isinstance(data, list):
    pkgs = data
elif isinstance(data, dict) and isinstance(data.get("info"), dict):
    pkgs = [data["info"]]
else:
    sys.stderr.write("feed-index: unexpected apk adbdump shape\n")
    sys.exit(1)
for pkg in pkgs:
    if not isinstance(pkg, dict):
        continue
    name = str(pkg.get("name") or "").strip()
    ver = str(pkg.get("version") or pkg.get("pkgver") or "").strip()
    if name != want:
        continue
    if not ver:
        sys.stderr.write("feed-index: empty pkgver for %s\n" % want)
        sys.exit(1)
    sys.stdout.write(ver + "\n")
    sys.exit(0)
sys.stderr.write("feed-index: %s missing from packages.adb dump\n" % want)
sys.exit(1)
' "$FEED_INDEX_PKG"
}

# Pinned guest queries (#421 slice 2). Compare per cell, not across formats.
# 23.05/24.10: opkg info Version:  (e.g. 0.1.45-1)
# 25.12: one OpenWrt apk query     (e.g. 0.1.45-r1)
# Consumed by qemu-install-from-feed.sh after sourcing this file.
# shellcheck disable=SC2034
FEED_INDEX_GUEST_OPKG_CMD='opkg info luci-app-fwlive'
# shellcheck disable=SC2034
FEED_INDEX_GUEST_APK_CMD='apk query --installed --format json --fields name,version luci-app-fwlive'

# Usage: feed_index_guest_opkg_version FILE
# FILE is `opkg info` / `opkg status` text. Require Status installed.
feed_index_guest_opkg_version() {
	local src="${1:-}" got
	[[ -n "$src" && -f "$src" ]] || {
		echo "feed-index: opkg info output not found: ${src:-}" >&2
		return 1
	}
	got="$(awk -v want="$FEED_INDEX_PKG" '
		BEGIN { RS = ""; FS = "\n"; found = 0; got = "" }
		{
			name = ""
			ver = ""
			st = ""
			for (i = 1; i <= NF; i++) {
				line = $i
				sub(/\r$/, "", line)
				if (line ~ /^Package:[[:space:]]*/) {
					name = line
					sub(/^Package:[[:space:]]*/, "", name)
				} else if (line ~ /^Version:[[:space:]]*/) {
					ver = line
					sub(/^Version:[[:space:]]*/, "", ver)
				} else if (line ~ /^Status:[[:space:]]*/) {
					st = line
					sub(/^Status:[[:space:]]*/, "", st)
				}
			}
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", ver)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", st)
			if (name != want)
				next
			n = split(st, stw, /[[:space:]]+/)
			if (n < 3 || stw[3] != "installed")
				next
			if (ver == "")
				next
			found = 1
			got = ver
		}
		END {
			if (!found || got == "")
				exit 1
			print got
		}
	' "$src")" || {
		echo "feed-index: $FEED_INDEX_PKG missing, empty Version, or not installed in $src" >&2
		return 1
	}
	[[ -n "$got" ]] || {
		echo "feed-index: empty installed Version for $FEED_INDEX_PKG" >&2
		return 1
	}
	printf '%s\n' "$got"
}

# Usage: feed_index_guest_apk_query_pkgver FILE
# FILE is output of FEED_INDEX_GUEST_APK_CMD. Never host apk / sdk apk.
feed_index_guest_apk_query_pkgver() {
	local src="${1:-}"
	[[ -n "$src" && -f "$src" ]] || {
		echo "feed-index: apk query output not found: ${src:-}" >&2
		return 1
	}
	command -v python3 >/dev/null 2>&1 || {
		echo "feed-index: python3 is required to parse apk query JSON" >&2
		return 1
	}
	python3 -c '
import json, sys
want = sys.argv[1]
path = sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError, UnicodeError) as exc:
    sys.stderr.write("feed-index: invalid apk query JSON: %s\n" % exc)
    sys.exit(1)
pkgs = []
if isinstance(data, list):
    pkgs = data
elif isinstance(data, dict) and "packages" in data:
    pkgs = data["packages"] if isinstance(data["packages"], list) else []
elif isinstance(data, dict):
    pkgs = [data]
else:
    sys.stderr.write("feed-index: unexpected apk query JSON shape\n")
    sys.exit(1)
for pkg in pkgs:
    if not isinstance(pkg, dict):
        continue
    name = str(pkg.get("name") or "").strip()
    ver = str(pkg.get("version") or pkg.get("pkgver") or "").strip()
    if name != want:
        continue
    if not ver:
        sys.stderr.write("feed-index: empty pkgver for %s in apk query\n" % want)
        sys.exit(1)
    sys.stdout.write(ver + "\n")
    sys.exit(0)
sys.stderr.write("feed-index: %s missing from apk query\n" % want)
sys.exit(1)
' "$FEED_INDEX_PKG" "$src"
}

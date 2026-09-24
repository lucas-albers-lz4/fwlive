#!/usr/bin/env bash
# Refuse GitHub Pages feed deploys that would move git_tag backwards (#590).
# Compare parsed vMAJOR.MINOR.PATCH tuples, not string order.
#
#   ./scripts/guard-feed-deploy.sh \
#     --staged feed-staging/manifest.json \
#     --live /tmp/live-manifest.json \
#     --tag v0.1.45 \
#     [--live-http CODE] \
#     [--allow-rollback]
#
# --live-http 404: bootstrap / wiped gh-pages. Validate staged git_tag against
# --tag and skip the live-version comparison. --live is then unused.
# --live-http 200 (or omitted): full guard, --live required.
# Any other --live-http code fails closed.
#
# Host/CI only — Bash + python3. Do not execute on the device.
set -euo pipefail

FEED_DEPLOY_MAJ=
FEED_DEPLOY_MIN=
FEED_DEPLOY_PAT=

feed_deploy_usage() {
	echo "usage: guard-feed-deploy.sh --staged MANIFEST --tag TAG [--live MANIFEST] [--live-http CODE] [--allow-rollback]" >&2
}

# Sets FEED_DEPLOY_MAJ/MIN/PAT. Rejects anything that is not vN.N.N
# with each component at most 9 digits (fits signed 64-bit Bash arithmetic).
feed_deploy_parse_version() {
	local tag="${1:-}"
	if [[ ! "$tag" =~ ^v([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})$ ]]; then
		echo "error: not a vMAJOR.MINOR.PATCH tag: '${tag}'" >&2
		return 1
	fi
	FEED_DEPLOY_MAJ="${BASH_REMATCH[1]}"
	FEED_DEPLOY_MIN="${BASH_REMATCH[2]}"
	FEED_DEPLOY_PAT="${BASH_REMATCH[3]}"
}

# Print lt, eq, or gt for $1 versus $2. Numeric, not lexicographic.
feed_deploy_cmp_tags() {
	local a_maj a_min a_pat b_maj b_min b_pat
	feed_deploy_parse_version "$1" || return 1
	a_maj="$FEED_DEPLOY_MAJ"
	a_min="$FEED_DEPLOY_MIN"
	a_pat="$FEED_DEPLOY_PAT"
	feed_deploy_parse_version "$2" || return 1
	b_maj="$FEED_DEPLOY_MAJ"
	b_min="$FEED_DEPLOY_MIN"
	b_pat="$FEED_DEPLOY_PAT"
	if ((10#$a_maj < 10#$b_maj)); then echo lt; return 0; fi
	if ((10#$a_maj > 10#$b_maj)); then echo gt; return 0; fi
	if ((10#$a_min < 10#$b_min)); then echo lt; return 0; fi
	if ((10#$a_min > 10#$b_min)); then echo gt; return 0; fi
	if ((10#$a_pat < 10#$b_pat)); then echo lt; return 0; fi
	if ((10#$a_pat > 10#$b_pat)); then echo gt; return 0; fi
	echo eq
}

# Print git_tag from a release manifest object. Fail closed on shape errors.
feed_deploy_read_git_tag() {
	local path="${1:-}"
	[[ -n "$path" && -f "$path" ]] || {
		echo "error: manifest not found: ${path:-}" >&2
		return 1
	}
	command -v python3 >/dev/null 2>&1 || {
		echo "error: python3 is required to parse manifest.json" >&2
		return 1
	}
	python3 - "$path" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError, UnicodeError) as exc:
    sys.stderr.write("error: invalid manifest JSON: %s\n" % exc)
    sys.exit(1)
if not isinstance(data, dict):
    sys.stderr.write("error: manifest JSON must be an object\n")
    sys.exit(1)
tag = data.get("git_tag")
if not isinstance(tag, str) or not tag:
    sys.stderr.write("error: manifest git_tag missing or empty\n")
    sys.exit(1)
if any(ord(c) < 32 for c in tag):
    sys.stderr.write("error: manifest git_tag contains control characters\n")
    sys.exit(1)
sys.stdout.write(tag + "\n")
PY
}

# Staged-manifest shape + git_tag == --tag. Independent of the live feed.
feed_deploy_validate_staged() {
	local staged_file="$1" want_tag="$2"
	local staged_tag

	if [[ "$want_tag" == *[[:cntrl:]]* ]]; then
		echo "error: selected tag contains control characters" >&2
		return 1
	fi
	feed_deploy_parse_version "$want_tag" >/dev/null || return 1

	staged_tag="$(feed_deploy_read_git_tag "$staged_file")" || return 1
	if [[ "$staged_tag" != "$want_tag" ]]; then
		echo "error: staged manifest git_tag '${staged_tag}' does not match selected release tag '${want_tag}'" >&2
		return 1
	fi
}

# After curl: 404 validates staged only; 200 compares live; anything else fails.
feed_deploy_after_live_fetch() {
	local http_code="$1" live_file="$2" staged_file="$3" want_tag="$4" allow="${5:-0}"

	case "$http_code" in
		404)
			echo "warn: live feed manifest not found (HTTP 404); validating staged manifest only (bootstrap / wiped gh-pages)" >&2
			feed_deploy_validate_staged "$staged_file" "$want_tag"
			return
			;;
		200)
			feed_deploy_guard "$staged_file" "$live_file" "$want_tag" "$allow"
			return
			;;
		*)
			echo "error: live feed manifest fetch returned HTTP ${http_code}" >&2
			return 1
			;;
	esac
}

feed_deploy_guard() {
	local staged_file="$1" live_file="$2" want_tag="$3" allow="${4:-0}"
	local live_tag cmp

	feed_deploy_validate_staged "$staged_file" "$want_tag" || return 1

	live_tag="$(feed_deploy_read_git_tag "$live_file")" || return 1
	cmp="$(feed_deploy_cmp_tags "$want_tag" "$live_tag")" || return 1
	case "$cmp" in
		eq|gt)
			echo "feed deploy guard: staged ${want_tag} vs live ${live_tag} (${cmp})" >&2
			return 0
			;;
		lt)
			if [[ "$allow" == "1" ]]; then
				echo "warn: deploying older feed tag '${want_tag}' over live '${live_tag}' because allow_rollback=true" >&2
				return 0
			fi
			echo "error: staged feed tag '${want_tag}' is older than live '${live_tag}'." >&2
			echo "Refusing to downgrade the published feed. Re-run with allow_rollback=true for a deliberate rollback." >&2
			return 1
			;;
		*)
			echo "error: unexpected version compare result '${cmp}'" >&2
			return 1
			;;
	esac
}

feed_deploy_main() {
	local staged="" live="" tag="" http_code="" allow=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--staged)
				[[ -n "${2:-}" ]] || { echo "error: --staged requires a path" >&2; feed_deploy_usage; return 1; }
				staged="$2"
				shift 2
				;;
			--live)
				[[ -n "${2:-}" ]] || { echo "error: --live requires a path" >&2; feed_deploy_usage; return 1; }
				live="$2"
				shift 2
				;;
			--tag)
				[[ -n "${2:-}" ]] || { echo "error: --tag requires a value" >&2; feed_deploy_usage; return 1; }
				tag="$2"
				shift 2
				;;
			--live-http)
				[[ -n "${2:-}" ]] || { echo "error: --live-http requires a status code" >&2; feed_deploy_usage; return 1; }
				http_code="$2"
				shift 2
				;;
			--allow-rollback)
				allow=1
				shift
				;;
			-h|--help)
				feed_deploy_usage
				return 2
				;;
			*)
				echo "unknown arg: $1" >&2
				feed_deploy_usage
				return 1
				;;
		esac
	done
	if [[ -z "$staged" || -z "$tag" ]]; then
		echo "error: --staged and --tag are required" >&2
		feed_deploy_usage
		return 1
	fi
	if [[ -n "$http_code" ]]; then
		feed_deploy_after_live_fetch "$http_code" "$live" "$staged" "$tag" "$allow"
		return
	fi
	if [[ -z "$live" ]]; then
		echo "error: --live is required unless --live-http 404" >&2
		feed_deploy_usage
		return 1
	fi
	feed_deploy_guard "$staged" "$live" "$tag" "$allow"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	feed_deploy_main "$@"
fi

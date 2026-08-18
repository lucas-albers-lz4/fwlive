#!/usr/bin/env bash
# Host tests for SDK digest pin-cache (R4) and secret-mount isolation (R7).
# Docker is mocked — no daemon needed.
# shellcheck disable=SC2015
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/lib/sdk-matrix.sh
source "$ROOT/scripts/lib/sdk-matrix.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# R7 host proof (no docker daemon): first secret-touching SDK use pins, and
# every container that bind-mounts a signing secret is --network none.
if grep -qE '^[[:space:]]*sdk_matrix_pull_and_pin ' "$ROOT/scripts/validate-feed-keys.sh" \
	&& ! grep -qE '^[[:space:]]*sdk_matrix_resolve ' "$ROOT/scripts/validate-feed-keys.sh"; then
	ok "R7: validate-feed-keys pins SDK (no resolve-only pull)"
else
	bad "R7: validate-feed-keys.sh must call pull_and_pin, not resolve"
fi
if grep -qE '^[[:space:]]*docker run --rm --network none --user root' "$ROOT/scripts/validate-feed-keys.sh"; then
	ok "R7: validate-feed-keys docker run is --network none"
else
	bad "R7: validate-feed-keys.sh docker run missing --network none"
fi
# The sign runs are guarded with `if docker run ...` (so failed signs still
# clean up temp dirs under `set -e`); match the optional `if ` prefix.
_secret_runs="$(grep -cE '^[[:space:]]*(if )?docker run --rm --network none --user root' "$ROOT/scripts/lib/feed-publish.sh" || true)"
if [[ "$_secret_runs" -eq 2 ]] \
	&& grep -A8 -- '--network none --user root' "$ROOT/scripts/lib/feed-publish.sh" | grep -q 'opkg-secret.key' \
	&& grep -A8 -- '--network none --user root' "$ROOT/scripts/lib/feed-publish.sh" | grep -q 'apk-secret.rsa' \
	&& grep -A8 -- '--network none --user root' "$ROOT/scripts/lib/feed-publish.sh" | grep -q '/feed/tools' \
	&& grep -A8 -- '--network none --user root' "$ROOT/scripts/lib/feed-publish.sh" | grep -q '/feed/lib' \
	&& ! grep -A12 -- '--network none --user root' "$ROOT/scripts/lib/feed-publish.sh" | grep -q 'SDK_MATRIX_VOLUME'; then
	ok "R7: opkg/apk secret runs are docker run --network none (no /builder volume)"
else
	bad "R7: feed-publish secret mounts must use docker run --network none without SDK volume (got ${_secret_runs})"
fi
_pin_calls="$(grep -cE '^[[:space:]]*feed_publish_apply_sdk_pin ' "$ROOT/scripts/lib/feed-publish.sh" || true)"
if [[ "$_pin_calls" -eq 2 ]] \
	&& grep -q 'sdk_matrix_read_digest_cache' "$ROOT/scripts/lib/feed-publish.sh"; then
	ok "R7: feed-publish applies digest pin before secret mounts"
else
	bad "R7: feed-publish must apply pin cache before secret mounts (got ${_pin_calls} apply_sdk_pin calls)"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SDK_MATRIX_DIGEST_CACHE_DIR="$TMP/sdk-digests"
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"

MOCK_PULL_FAIL=0

docker() {
	local img
	case "$1" in
		pull)
			[[ "$MOCK_PULL_FAIL" != 1 ]] || return 1
			[[ -n "${MOCK_PULL_LOG:-}" ]] && echo "pull $2" >> "$MOCK_PULL_LOG"
			return 0
			;;
		image)
			[[ "$2" == "inspect" ]] || return 0
			img="${!#}"
			if [[ "${3:-}" == "--format" ]]; then
				case "$4" in
					*RepoDigests*)
						[[ -n "${MOCK_REPO:-}" ]] && printf '%s\n' "$MOCK_REPO"
						return 0
						;;
					*)
						[[ -n "${MOCK_ID:-}" ]] && printf '%s' "$MOCK_ID"
						return 0
						;;
				esac
			fi
			return 0
			;;
		*) return 0 ;;
	esac
}

want='ghcr.io/openwrt/sdk@sha256:dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444'
decoy='registry.example.net/sdk@sha256:decoydecoydecoydecoydecoydecoydecoydecoydecoydecoydecoydecoydecoydeco'
MOCK_REPO="${decoy}
${want}"
MOCK_ID=''

got="$(sdk_matrix_image_digest x86-64 23.05)"
if [[ "$got" == "$want" ]]; then
	ok "digest x86-64/23.05 selects ghcr.io prefix, not decoy"
else
	bad "digest x86-64/23.05: got '${got}' want '${want}'"
fi

# Pin file: digest returned without a second pull.
rm -rf "${SDK_MATRIX_DIGEST_CACHE_DIR:?}"/*
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"
MOCK_PULL_LOG="$TMP/pull-pin.log"
: > "$MOCK_PULL_LOG"
sdk_matrix_pull_and_pin x86-64 23.05 >/dev/null
pulls1="$(wc -l < "$MOCK_PULL_LOG" | tr -d ' ')"
got="$(sdk_matrix_image_digest x86-64 23.05)"
pulls2="$(wc -l < "$MOCK_PULL_LOG" | tr -d ' ')"
if [[ "$got" == "$want" && "$pulls1" == "1" && "$pulls2" == "1" ]]; then
	ok "R4 pin cache avoids re-pull"
else
	bad "R4 pin cache: got=$got pulls=$pulls1/$pulls2"
fi
unset MOCK_PULL_LOG

# Fallback: empty RepoDigests → @sha256:<image id> + WARNING
rm -rf "${SDK_MATRIX_DIGEST_CACHE_DIR:?}"/*
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"
MOCK_REPO=''
MOCK_ID='sha256:feedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeed'
warn="$TMP/fallback-warn.txt"
got="$(sdk_matrix_image_digest x86-64 23.05 2>"$warn")"
if [[ "$got" == "@sha256:feedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeed" ]]; then
	ok "fallback digest uses image id"
else
	bad "fallback digest: got '$got'"
fi
grep -qi 'RepoDigest' "$warn" && ok "fallback emitted WARNING" || bad "no WARNING for fallback"

# Abort: pull fails → non-zero
rm -rf "${SDK_MATRIX_DIGEST_CACHE_DIR:?}"/*
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"
MOCK_PULL_FAIL=1
if sdk_matrix_image_digest x86-64 23.05 >/dev/null 2>&1; then
	bad "digest should abort when pull fails"
else
	ok "digest aborts when pull fails"
fi
MOCK_PULL_FAIL=0

# Abort: no RepoDigests / id
rm -rf "${SDK_MATRIX_DIGEST_CACHE_DIR:?}"/*
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"
MOCK_REPO=''
MOCK_ID=''
if sdk_matrix_image_digest x86-64 23.05 >/dev/null 2>&1; then
	bad "digest should abort with no resolvable source"
else
	ok "digest aborts with no resolvable source"
fi

# sdk_matrix_pull must re-resolve tags even when the image is already local.
MOCK_PULL_LOG="$TMP/pulls.log"
: > "$MOCK_PULL_LOG"
MOCK_REPO="$want"
sdk_matrix_resolve x86-64 23.05
sdk_matrix_pull
pulls="$(grep -c 'ghcr.io/openwrt/sdk:' "$MOCK_PULL_LOG" || true)"
if [[ "$pulls" -ge 1 ]]; then
	ok "sdk_matrix_pull always re-resolves (pull fired on present image)"
else
	bad "sdk_matrix_pull skipped pull on present image (stale digest risk)"
fi
unset MOCK_PULL_LOG

[ "$fail" = "0" ] || exit 1
echo "ALL TESTS PASSED"

#!/usr/bin/env bash
# Host proof: parsed-tag feed deploy guard (#590). No network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/guard-feed-deploy.sh"
export LC_ALL=C

fail() {
	echo "guard-feed-deploy test FAIL: $*" >&2
	exit 1
}

ok() {
	echo "guard-feed-deploy test OK: $*"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

write_manifest() {
	local dest="$1" tag="$2"
	printf '{\n  "git_tag": "%s",\n  "packages": []\n}\n' "$tag" >"$dest"
}

run_guard() {
	local extra=()
	if [[ "${1:-}" == --allow-rollback ]]; then
		extra=(--allow-rollback)
		shift
	fi
	set +e
	"$GUARD" --staged "$1" --live "$2" --tag "$3" "${extra[@]}" >"$TMP/out" 2>"$TMP/err"
	rc=$?
	set -e
}

# String order must not match version order for these pairs.
left=v0.1.9
right=v0.1.10
[[ "$left" > "$right" ]] || fail "fixture: bash string compare should rank v0.1.9 after v0.1.10"
left=v0.9.0
right=v0.10.0
[[ "$left" > "$right" ]] || fail "fixture: bash string compare should rank v0.9.0 after v0.10.0"
ok "string-order traps are discriminating"

write_manifest "$TMP/staged.json" "v0.1.45"
write_manifest "$TMP/live.json" "v0.1.45"
run_guard "$TMP/staged.json" "$TMP/live.json" "v0.1.45"
[[ "$rc" -eq 0 ]] || fail "equal tags must succeed ($(cat "$TMP/err"))"
ok "equal tag republish succeeds"

write_manifest "$TMP/staged.json" "v0.1.46"
write_manifest "$TMP/live.json" "v0.1.45"
run_guard "$TMP/staged.json" "$TMP/live.json" "v0.1.46"
[[ "$rc" -eq 0 ]] || fail "newer staged tag must succeed ($(cat "$TMP/err"))"
ok "newer staged tag succeeds"

write_manifest "$TMP/staged.json" "v0.1.44"
write_manifest "$TMP/live.json" "v0.1.45"
run_guard "$TMP/staged.json" "$TMP/live.json" "v0.1.44"
[[ "$rc" -ne 0 ]] || fail "older staged tag must fail without --allow-rollback"
grep -Fq "older than live 'v0.1.45'" "$TMP/err" \
	|| fail "downgrade must name live tag ($(cat "$TMP/err"))"
grep -Fq "allow_rollback=true" "$TMP/err" \
	|| fail "downgrade must mention allow_rollback ($(cat "$TMP/err"))"
ok "older tag without rollback fails with a clear message"

run_guard --allow-rollback "$TMP/staged.json" "$TMP/live.json" "v0.1.44"
[[ "$rc" -eq 0 ]] || fail "older tag with --allow-rollback must succeed ($(cat "$TMP/err"))"
grep -Fq "allow_rollback=true" "$TMP/err" \
	|| fail "rollback path must warn ($(cat "$TMP/err"))"
ok "deliberate rollback requires --allow-rollback"

write_manifest "$TMP/staged.json" "v0.1.44"
write_manifest "$TMP/live.json" "v0.1.45"
run_guard --allow-rollback "$TMP/staged.json" "$TMP/live.json" "v0.1.45"
[[ "$rc" -ne 0 ]] || fail "staged git_tag mismatch must fail even with rollback"
grep -Fq "does not match selected release tag" "$TMP/err" \
	|| fail "mismatch must name selected tag ($(cat "$TMP/err"))"
ok "staged git_tag must match selected tag"

# Version order, not string order: upgrade v0.1.9 → v0.1.10 must pass.
write_manifest "$TMP/staged.json" "v0.1.10"
write_manifest "$TMP/live.json" "v0.1.9"
run_guard "$TMP/staged.json" "$TMP/live.json" "v0.1.10"
[[ "$rc" -eq 0 ]] || fail "v0.1.10 over live v0.1.9 must succeed (not string sort) ($(cat "$TMP/err"))"
ok "v0.1.10 is newer than v0.1.9"

write_manifest "$TMP/staged.json" "v0.1.9"
write_manifest "$TMP/live.json" "v0.1.10"
run_guard "$TMP/staged.json" "$TMP/live.json" "v0.1.9"
[[ "$rc" -ne 0 ]] || fail "v0.1.9 over live v0.1.10 must fail (not string sort)"
ok "v0.1.9 is older than v0.1.10"

write_manifest "$TMP/staged.json" "v0.10.0"
write_manifest "$TMP/live.json" "v0.9.0"
run_guard "$TMP/staged.json" "$TMP/live.json" "v0.10.0"
[[ "$rc" -eq 0 ]] || fail "v0.10.0 over live v0.9.0 must succeed ($(cat "$TMP/err"))"
ok "v0.10.0 is newer than v0.9.0"

write_manifest "$TMP/staged.json" "v0.9.0"
write_manifest "$TMP/live.json" "v0.10.0"
run_guard "$TMP/staged.json" "$TMP/live.json" "v0.9.0"
[[ "$rc" -ne 0 ]] || fail "v0.9.0 over live v0.10.0 must fail"
ok "v0.9.0 is older than v0.10.0"

printf '{ "packages": [] }\n' >"$TMP/nogit.json"
write_manifest "$TMP/staged.json" "v0.1.45"
run_guard "$TMP/staged.json" "$TMP/nogit.json" "v0.1.45"
[[ "$rc" -ne 0 ]] || fail "missing live git_tag must fail closed"
ok "missing git_tag fails closed"

printf 'not-json\n' >"$TMP/bad.json"
run_guard "$TMP/staged.json" "$TMP/bad.json" "v0.1.45"
[[ "$rc" -ne 0 ]] || fail "invalid live JSON must fail closed"
ok "invalid JSON fails closed"

write_manifest "$TMP/staged.json" "v1"
write_manifest "$TMP/live.json" "v0.1.45"
run_guard "$TMP/staged.json" "$TMP/live.json" "v1"
[[ "$rc" -ne 0 ]] || fail "non-semver selected tag must fail"
ok "non-semver tag fails"

# 19-digit components overflow signed 64-bit Bash arithmetic (luna #590).
huge=v9223372036854775808.0.0
write_manifest "$TMP/staged.json" "$huge"
write_manifest "$TMP/live.json" "v0.1.45"
run_guard "$TMP/staged.json" "$TMP/live.json" "$huge"
[[ "$rc" -ne 0 ]] || fail "19-digit major must be rejected before Bash arithmetic"
ok "oversized version component fails"

WF="$ROOT/.github/workflows/publish-packages.yml"
grep -A5 'allow_rollback:' "$WF" | grep -q 'default: false' \
	|| fail "allow_rollback must default off"
grep -Fq './scripts/guard-feed-deploy.sh' "$WF" \
	|| fail "workflow must invoke guard-feed-deploy.sh"
grep -Fq '${FWLIVE_FEED_BASE_URL}/manifest.json?cb=${GITHUB_RUN_ID}' "$WF" \
	|| fail "workflow must cache-bust the live Pages manifest fetch"
grep -Fq "Cache-Control: no-cache" "$WF" \
	|| fail "workflow must send Cache-Control: no-cache when fetching the live manifest"
awk '
	/Guard against feed downgrade/ { g = NR }
	/Deploy to GitHub Pages/ { d = NR }
	END { exit (g && d && g < d) ? 0 : 1 }
' "$WF" || fail "guard step must run before Pages deploy"
grep -Fq 'tests/guard-feed-deploy.test.sh' "$ROOT/scripts/fwlive-test.sh" \
	|| fail "fwlive-test.sh must run this host test"
ok "publish-packages.yml wires the guard"

echo "guard-feed-deploy helper test passed"

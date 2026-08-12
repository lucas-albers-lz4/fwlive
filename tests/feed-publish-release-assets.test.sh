#!/usr/bin/env bash
# Guard: GitHub Release assets need unique basenames (one ipk per OpenWrt line).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"

assert_eq() {
	local got="$1" want="$2" msg="$3"
	if [[ "$got" != "$want" ]]; then
		echo "FAIL: $msg (got '$got', want '$want')" >&2
		exit 1
	fi
}

assert_eq "$(feed_publish_release_asset_basename \
	"${ROOT}/out/x86_64/21.02.7/fwlive/luci-app-fwlive_0.1.16_all.ipk")" \
	"luci-app-fwlive_0.1.16_21.02_all.ipk" \
	"21.02 ipk suffix"

assert_eq "$(feed_publish_release_asset_basename \
	"${ROOT}/out/x86_64/22.03.7/fwlive/luci-app-fwlive_0.1.16_all.ipk")" \
	"luci-app-fwlive_0.1.16_22.03_all.ipk" \
	"22.03 ipk suffix"

assert_eq "$(feed_publish_release_asset_basename \
	"${ROOT}/out/x86_64/23.05.5/fwlive/luci-app-fwlive_0.1.16_all.ipk")" \
	"luci-app-fwlive_0.1.16_23.05_all.ipk" \
	"23.05 ipk suffix"

assert_eq "$(feed_publish_release_asset_basename \
	"${ROOT}/out/x86_64/25.12.5/fwlive/luci-app-fwlive-0.1.16-r1.apk")" \
	"luci-app-fwlive-0.1.16-r1.apk" \
	"apk unchanged"

fixture="$(mktemp -d)"
staging="$(mktemp -d)"
trap 'rm -rf "$fixture" "$staging"' EXIT
export FEED_PUBLISH_ROOT="$fixture"
mkdir -p "${fixture}/out/x86_64"/{21.02.7,22.03.7,23.05.5}/fwlive
echo ipk21 > "${fixture}/out/x86_64/21.02.7/fwlive/luci-app-fwlive_0.1.16_all.ipk"
echo ipk22 > "${fixture}/out/x86_64/22.03.7/fwlive/luci-app-fwlive_0.1.16_all.ipk"
echo ipk23 > "${fixture}/out/x86_64/23.05.5/fwlive/luci-app-fwlive_0.1.16_all.ipk"
feed_publish_stage_release_assets "$staging"
test -f "$staging/luci-app-fwlive_0.1.16_21.02_all.ipk"
test -f "$staging/luci-app-fwlive_0.1.16_22.03_all.ipk"
test -f "$staging/luci-app-fwlive_0.1.16_23.05_all.ipk"

# Guard #144: manifest records ONE SDK image digest per target×version cell.
# Docker is mocked so the test is hermetic (RepoDigests source + the
# empty-RepoDigests → @sha256:<image ID> fallback path + abort path).
mock_bin="${fixture}/mock-bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
image="${!#}"
case "${1:-}" in
	image)
		case "${2:-}" in
			pull)
				# Record the pull so tests can assert the pull path ran.
				[[ -n "${MOCK_PULL_LOG:-}" ]] && echo "pull $image" >> "$MOCK_PULL_LOG"
				# MOCK_PULL_FAIL=1 simulates a failed pull — the production
				# code must abort (sdk_matrix_pull || return 1), not fall
				# through to a misleading inspect.
				[[ "${MOCK_PULL_FAIL:-0}" != "1" ]] || exit 1
				exit 0
				;;
			inspect)
				# Bare existence check (no --format): MOCK_IMAGE_ABSENT=1
				# simulates the image not being present → pull fires.
				if [[ "${3:-}" == "--format" ]]; then
					case "$4" in
						*RepoDigests*)
							[[ "${MOCK_REPO_DIGESTS:-1}" != "0" ]] || exit 1
							# Emit ALL RepoDigests in the SAME order docker
							# would (multiple registries). The production code
							# must select the one matching the image's repo
							# (ghcr.io/openwrt/sdk), NOT RepoDigests[0] — the
							# decoy (ghcrXio) sorts first on some docker
							# versions, and a plain [0] pick would take it.
							# MOCK_MULTI_REPO=1 emits the decoy FIRST.
							if [[ "${MOCK_MULTI_REPO:-0}" == "1" ]]; then
								printf 'ghcrXio/openwrt/sdk@sha256:%s\n' "$(printf '%s' "decoy-$image" | sha256sum | awk '{print $1}')"
								printf '%s@sha256:%s\n' "${image%%:*}" "$(printf '%s' "$image" | sha256sum | awk '{print $1}')"
							else
								printf '%s@sha256:%s\n' "${image%%:*}" "$(printf '%s' "$image" | sha256sum | awk '{print $1}')"
							fi
							exit 0
							;;
						*)
							# .Id path — MOCK_NO_ID=1 simulates an unresolvable image.
							[[ "${MOCK_NO_ID:-0}" != "1" ]] || exit 1
							printf 'sha256:%s\n' "$(printf '%s' "$image" | sha256sum | awk '{print $1}')"
							exit 0
							;;
					esac
				fi
				[[ "${MOCK_IMAGE_ABSENT:-0}" != "1" ]] || exit 1
				exit 0
				;;
		esac
		;;
esac
exit 0
EOF
chmod +x "$mock_bin/docker"
PATH="$mock_bin:$PATH"

mkdir -p "${fixture}/manifest-staging" "${fixture}/fallback-staging" "${fixture}/abort-staging" "${fixture}/pull-staging" "${fixture}/pullfail-staging" "${fixture}/multi-staging"
# Assert the pull path runs: image absent (bare inspect fails) → explicit
# pull before the digest inspect (luna fold 2026-08-10).
pull_log="$(mktemp)"
export MOCK_PULL_LOG="$pull_log" MOCK_IMAGE_ABSENT=1
feed_publish_write_manifest "${fixture}/pull-staging" test-tag
grep -q '^pull ghcr.io/openwrt/sdk:' "$pull_log" || { echo "FAIL: sdk_matrix_pull not called"; exit 1; }
unset MOCK_IMAGE_ABSENT
feed_publish_write_manifest "${fixture}/manifest-staging" test-tag
grep -q '^pull ghcr.io/openwrt/sdk:' "$pull_log" || { echo "FAIL: sdk_matrix_pull not called"; exit 1; }
test -f "${fixture}/manifest-staging/manifest.json"
grep -q '"openwrt": "21.02"' "${fixture}/manifest-staging/manifest.json"
grep -q '"sha256":' "${fixture}/manifest-staging/manifest.json"
grep -q '"sdk_image": "ghcr.io/openwrt/sdk:x86-64-21.02.7"' "${fixture}/manifest-staging/manifest.json"
grep -q '"sdk_digest": "ghcr.io/openwrt/sdk@sha256:' "${fixture}/manifest-staging/manifest.json"
command -v node >/dev/null 2>&1 && node -e '
	const fs = require("fs");
	const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
	if (!Array.isArray(m.packages) || m.packages.length < 3) process.exit(1);
	for (const p of m.packages) {
		if (!/^ghcr\.io\/openwrt\/sdk@sha256:[0-9a-f]{64}$/.test(p.sdk_digest || "")) process.exit(1);
	}
' "${fixture}/manifest-staging/manifest.json"

# Multi-registry RepoDigests: the production code must select the digest
# matching ghcr.io/openwrt/sdk, NOT RepoDigests[0] (the ghcrXio decoy is
# emitted FIRST, like docker sometimes orders multiple registries).
mkdir -p "${fixture}/multi-staging"
export MOCK_MULTI_REPO=1
feed_publish_write_manifest "${fixture}/multi-staging" test-tag
grep -q '"sdk_digest": "ghcr.io/openwrt/sdk@sha256:' "${fixture}/multi-staging/manifest.json" \
	|| { echo "FAIL: multi-registry manifest must select the ghcr.io digest, not the decoy"; exit 1; }
grep -q 'ghcrXio' "${fixture}/multi-staging/manifest.json" \
	&& { echo "FAIL: decoy digest must NOT appear in the manifest"; exit 1; }
unset MOCK_MULTI_REPO
echo "multi-registry digest selection OK"

# Failed pull must abort (sdk_matrix_pull || return 1) — a failed pull
# followed by a successful inspect would record a digest for an image that
# was never pulled (luna fold 2026-08-10).
pullfail_warn="$(mktemp)"
export MOCK_IMAGE_ABSENT=1 MOCK_PULL_FAIL=1
if feed_publish_write_manifest "${fixture}/pullfail-staging" test-tag 2>"$pullfail_warn"; then
	echo "FAIL: manifest generation must abort when the SDK pull fails" >&2
	exit 1
fi
unset MOCK_IMAGE_ABSENT MOCK_PULL_FAIL
echo "pull-failure abort OK"

# Empty RepoDigests → fallback to @sha256:<image ID> with a documented warning.
fallback_warn="$(mktemp)"
export MOCK_REPO_DIGESTS=0
feed_publish_write_manifest "${fixture}/fallback-staging" test-tag 2>"$fallback_warn"
grep -q '"sdk_digest": "@sha256:' "${fixture}/fallback-staging/manifest.json"
grep -qi 'has no .*RepoDigest' "$fallback_warn"
command -v node >/dev/null 2>&1 && node -e '
	const fs = require("fs");
	const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
	for (const p of m.packages) {
		if (!/^@sha256:[0-9a-f]{64}$/.test(p.sdk_digest || "")) process.exit(1);
	}
' "${fixture}/fallback-staging/manifest.json"
export MOCK_REPO_DIGESTS=1

# Neither RepoDigests nor .Id resolvable → manifest generation must FAIL
# (no empty digest recorded silently; luna fold 2026-08-10).
abort_warn="$(mktemp)"
export MOCK_REPO_DIGESTS=0 MOCK_NO_ID=1
if feed_publish_write_manifest "${fixture}/abort-staging" test-tag 2>"$abort_warn"; then
	echo "FAIL: manifest generation must abort when no digest source exists" >&2
	exit 1
fi
grep -qi 'cannot resolve SDK image digest' "$abort_warn" || {
	echo "FAIL: abort must report the unresolvable digest" >&2
	exit 1
}
if [[ -s "${fixture}/abort-staging/manifest.json" ]] && \
   grep -q '"sdk_digest": ""' "${fixture}/abort-staging/manifest.json"; then
	echo "FAIL: abort path must not record an empty digest" >&2
	exit 1
fi
unset MOCK_REPO_DIGESTS MOCK_NO_ID

echo "feed-publish release asset tests passed"

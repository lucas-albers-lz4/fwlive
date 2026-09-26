#!/usr/bin/env bash
# Pin persist-credentials on every checkout and Node 22 on publish lint (#817 #842).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_checkout_pins() {
	local wf="$1"
	local checkouts persist
	checkouts="$(grep -c 'uses: actions/checkout@' "$wf")"
	persist="$(grep -c 'persist-credentials: false' "$wf")"
	[[ "$checkouts" -gt 0 ]] || fail "$wf: no checkout steps"
	[[ "$checkouts" -eq "$persist" ]] || fail "$wf: checkout=$checkouts persist-credentials=$persist"
}

assert_checkout_pins "${ROOT}/.github/workflows/fwlive-test.yml"
assert_checkout_pins "${ROOT}/.github/workflows/publish-packages.yml"

pub="${ROOT}/.github/workflows/publish-packages.yml"
grep -Fq 'actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38' "$pub" \
	|| fail "publish-packages.yml missing digest-pinned setup-node"
awk '
	/uses: actions\/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38/ { n=1; next }
	n && /node-version:/ {
		if ($0 ~ /['\''"]22['\''"]/) { found=1; next }
		exit 1
	}
	n && /package-manager-cache: false/ { nocache=1 }
	n && /^- / { exit (found && nocache) ? 0 : 1 }
	END { exit (found && nocache) ? 0 : 1 }
' "$pub" || fail "publish-packages.yml setup-node must be Node 22 with package-manager-cache: false"
# lint gate must run after the pin
awk '
	/uses: actions\/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38/ { pin=NR }
	/validate-baseline\.sh/ { gate=NR }
	END { exit (pin && gate && pin < gate) ? 0 : 1 }
' "$pub" || fail "publish-packages.yml must pin Node before validate-baseline.sh"

echo "ci workflow pins (#817 #842) passed"

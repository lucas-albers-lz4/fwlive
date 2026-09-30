#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Run the small TLA+ models and assert that the three known counterexamples
# remain counterexamples. TLC runs in single-worker mode for stable liveness
# checking. This script is CI/developer tooling only; it is not packaged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLA_VERSION=1.7.4
TLA_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
TLA_URL="https://github.com/tlaplus/tlaplus/releases/download/v${TLA_VERSION}/tla2tools.jar"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "formal TLC FAIL: $*" >&2; exit 1; }
ok() { echo "formal TLC OK: $*"; }

if [[ -n "${TLA2TOOLS_JAR:-}" ]]; then
	JAR="$TLA2TOOLS_JAR"
	[[ -f "$JAR" ]] || fail "TLA2TOOLS_JAR does not name a file: $JAR"
else
	JAR="$WORK/tla2tools.jar"
	curl -fsSL --retry 2 "$TLA_URL" -o "$JAR"
fi

# Both execution helpers change into model directories; preserve the caller's
# JAR filename while making its location independent of those directories.
case "$JAR" in
	/*) ;;
	*) JAR="$PWD/$JAR" ;;
esac

actual_sha="$(sha256sum "$JAR" | awk '{print $1}')"
[[ "$actual_sha" == "$TLA_SHA256" ]] \
	|| fail "TLA+ ${TLA_VERSION} jar SHA-256 mismatch: $actual_sha"

run_pass() {
	local dir="$1" module="$2" cfg="$3"
	(
		cd "$ROOT/formal/$dir"
		java -jar "$JAR" -workers 1 -metadir "$WORK/${module}-${cfg}-states" \
			-config "$cfg" "$module.tla"
	)
	ok "$module / $cfg"
}

run_expected_violation() {
	local dir="$1" module="$2" cfg="$3" property="$4" output status
	set +e
	output="$(cd "$ROOT/formal/$dir" && java -jar "$JAR" -workers 1 \
		-metadir "$WORK/${module}-${cfg}-states" -config "$cfg" "$module.tla" 2>&1)"
	status=$?
	set -e
	if [[ "$status" -eq 0 ]]; then
		fail "$module / $cfg unexpectedly passed; expected $property violation"
	fi
	if ! grep -Fq "Invariant $property is violated" <<<"$output"; then
		printf '%s\n' "$output" >&2
		fail "$module / $cfg failed for a reason other than $property"
	fi
	ok "$module / $cfg reports expected $property counterexample"
}

run_pass wan-log-lock WanLogLock WanLogLock.cfg
run_pass wan-log-lock WanLogLockTimed WanLogLockTimedSafety.cfg
run_pass wan-log-lock WanLogRollbackRevision WanLogRollbackRevision.cfg
run_expected_violation wan-log-lock WanLogLockTimed WanLogLockTimedStranding.cfg NoOrphanStaging
run_expected_violation wan-log-lock WanLogRollbackAba WanLogRollbackAba.cfg NoOverwriteForeignIntent
run_pass hostname-dispose HostnameDispose HostnameDispose.cfg
run_expected_violation hostname-dispose HostnameDispose HostnameDisposeUngated.cfg NoLateWrite

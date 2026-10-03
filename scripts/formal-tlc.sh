#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Run the small TLA+ models and assert that the eight known counterexamples
# remain counterexamples. TLC runs in single-worker mode for stable liveness
# checking. This script is CI/developer tooling only; it is not packaged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLA_VERSION=1.7.4
TLA_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
TLA_URL="https://github.com/tlaplus/tlaplus/releases/download/v${TLA_VERSION}/tla2tools.jar"
fail() { echo "formal TLC FAIL: $*" >&2; exit 1; }
ok() { echo "formal TLC OK: $*"; }

command -v java >/dev/null 2>&1 || fail "java is required; install a JRE (for example openjdk-17-jre-headless)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -n "${TLA2TOOLS_JAR:-}" ]]; then
	JAR="$TLA2TOOLS_JAR"
	[[ -f "$JAR" ]] || fail "TLA2TOOLS_JAR does not name a file: $JAR"
else
	JAR="$WORK/tla2tools.jar"
	curl -fsSL --connect-timeout 10 --max-time 120 --retry 2 "$TLA_URL" -o "$JAR"
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

# A violated temporal property prints "Temporal properties were violated." with no
# property name (TLC 2.19), so this arm is keyed to the cfg's single PROPERTY.
run_expected_property_violation() {
	local dir="$1" module="$2" cfg="$3" property="$4" output status config_file declared_properties
	config_file="$ROOT/formal/$dir/$cfg"
	[[ -f "$config_file" ]] || fail "$module / $cfg config is missing"
	# This counterexample cfg deliberately uses only one identifier per
	# SPECIFICATION/INVARIANT/PROPERTY line. Fail closed on richer TLC syntax:
	# TLC accepts additional PROPERTY operands on this or following lines.
	declared_properties="$(awk '
		{ sub(/\\\*.*/, "") }
		NF == 0 { next }
		NF != 2 || $1 !~ /^(SPECIFICATION|INVARIANT|PROPERTY)$/ ||
			$2 !~ /^[A-Za-z_][A-Za-z0-9_]*$/ { bad = 1; next }
		$1 == "PROPERTY" { properties = properties $2 "\n" }
		END {
			if (bad) print "unsupported configuration syntax"
			else printf "%s", properties
		}
	' "$config_file")"
	if [[ "$declared_properties" != "$property" ]]; then
		fail "$module / $cfg must declare exactly PROPERTY $property (found: ${declared_properties:-none})"
	fi
	set +e
	output="$(cd "$ROOT/formal/$dir" && java -jar "$JAR" -workers 1 \
		-metadir "$WORK/${module}-${cfg}-states" -config "$cfg" "$module.tla" 2>&1)"
	status=$?
	set -e
	if [[ "$status" -eq 0 ]]; then
		fail "$module / $cfg unexpectedly passed; expected a $property violation"
	fi
	if ! grep -Fq "Temporal properties were violated" <<<"$output"; then
		printf '%s\n' "$output" >&2
		fail "$module / $cfg failed for a reason other than the $property property"
	fi
	ok "$module / $cfg reports expected $property property counterexample"
}

run_trace_replay_cases() {
	local cases="$1" mode property config output status number=0
	[[ -f "$cases" ]] || fail "trace replay case list is missing: $cases"
	[[ -f "$ROOT/formal/wan-log-lock/WanLogRollbackReplay.tla" ]] \
		|| fail "rollback trace replay module is missing"
	while IFS='|' read -r mode property config || [[ -n "${mode:-}${property:-}${config:-}" ]]; do
		[[ -n "${mode:-}" ]] || continue
		[[ -f "$config" ]] || fail "trace replay config is missing: $config"
		number=$((number + 1))
		set +e
		output="$(cd "$ROOT/formal/wan-log-lock" && java -jar "$JAR" -workers 1 \
			-metadir "$WORK/rollback-replay-${number}-states" -config "$config" \
			WanLogRollbackReplay.tla 2>&1)"
		status=$?
		set -e
		case "$mode" in
			pass)
				if [[ "$status" -ne 0 ]] || ! grep -Fq "Model checking completed. No error has been found." <<<"$output"; then
					printf '%s\n' "$output" >&2
					fail "observed rollback trace unexpectedly rejected: $config"
				fi
				ok "observed rollback trace passes: $config"
				;;
			reject)
				if [[ "$status" -eq 0 ]] || ! grep -Fq "Invariant $property is violated" <<<"$output"; then
					printf '%s\n' "$output" >&2
					fail "mutated rollback trace did not violate $property: $config"
				fi
				ok "mutated rollback trace rejected by $property: $config"
				;;
			*) fail "unknown trace replay case mode: $mode" ;;
		esac
	done < "$cases"
	[[ "$number" -gt 0 ]] || fail "trace replay case list is empty"
}

if [[ -n "${FWLIVE_TLC_REPLAY_CASES:-}" ]]; then
	run_trace_replay_cases "$FWLIVE_TLC_REPLAY_CASES"
	exit 0
fi

run_pass wan-log-lock WanLogLock WanLogLock.cfg
run_pass wan-log-lock WanLogLockTimed WanLogLockTimedSafety.cfg
run_pass wan-log-lock WanLogRollbackRevision WanLogRollbackRevision.cfg
run_expected_violation wan-log-lock WanLogLockTimed WanLogLockTimedStranding.cfg NoOrphanStaging
run_expected_violation wan-log-lock WanLogRollbackAba WanLogRollbackAba.cfg NoOverwriteForeignIntent
run_expected_property_violation wan-log-lock WanLogRollbackRevision WanLogRollbackRevisionUnfair.cfg RestoreLandsWithoutForeignCommit
run_pass wan-log-lock WanLogRollbackOutcomes WanLogRollbackOutcomesEnable.cfg
run_pass wan-log-lock WanLogRollbackOutcomes WanLogRollbackOutcomesDisable.cfg
run_pass wan-log-lock WanLogRollbackOutcomes WanLogRollbackOutcomesFailuresEnable.cfg
run_pass wan-log-lock WanLogRollbackOutcomes WanLogRollbackOutcomesFailuresDisable.cfg
run_expected_violation wan-log-lock WanLogRollbackOutcomes \
	WanLogRollbackOutcomesValueOnly.cfg NoRestoreAfterNewerIntent
run_expected_violation wan-log-lock WanLogRollbackOutcomes \
	WanLogRollbackOutcomesWrongRestore.cfg RestoreValueIsPrevious
run_expected_violation wan-log-lock WanLogRollbackOutcomes \
	WanLogRollbackOutcomesValueOnlyDisable.cfg NoRestoreAfterNewerIntent
run_expected_violation wan-log-lock WanLogRollbackOutcomes \
	WanLogRollbackOutcomesWrongRestoreDisable.cfg RestoreValueIsPrevious
run_pass hostname-dispose HostnameDispose HostnameDispose.cfg
run_expected_violation hostname-dispose HostnameDispose HostnameDisposeUngated.cfg NoLateWrite

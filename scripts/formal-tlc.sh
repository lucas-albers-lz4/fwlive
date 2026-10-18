#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Run the versioned TLA+ models and assert that ten counterexample configs
# remain counterexamples (seven invariants and three temporal properties).
# TLC runs in single-worker mode for stable liveness
# checking. This script is CI/developer tooling only; it is not packaged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLA_VERSION=1.7.4
TLA_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
TLA_URL="https://github.com/tlaplus/tlaplus/releases/download/v${TLA_VERSION}/tla2tools.jar"
DIAGNOSTICS_DIR=''
fail() {
	echo "formal TLC FAIL: $*" >&2
	if [[ -n "$DIAGNOSTICS_DIR" ]]; then
		printf 'formal TLC FAIL: %s\n' "$*" >>"$DIAGNOSTICS_DIR/formal-tlc-failures.log" 2>/dev/null || true
	fi
	exit 1
}
ok() { echo "formal TLC OK: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [[ -n "${FWLIVE_TLC_DIAGNOSTICS_DIR:-}" ]]; then
	DIAGNOSTICS_DIR="$FWLIVE_TLC_DIAGNOSTICS_DIR"
	case "$DIAGNOSTICS_DIR" in
		/*) ;;
		*) DIAGNOSTICS_DIR="$PWD/$DIAGNOSTICS_DIR" ;;
	esac
	mkdir -p "$DIAGNOSTICS_DIR"
else
	DIAGNOSTICS_DIR="$WORK/diagnostics"
	mkdir -p "$DIAGNOSTICS_DIR"
fi

for required_tool in java sha256sum awk; do
	command -v "$required_tool" >/dev/null 2>&1 || {
		if [[ "$required_tool" == java ]]; then
			fail "java is required; install a JRE to run TLC"
		fi
		fail "$required_tool is required to run TLC"
	}
done

if [[ -n "${TLA2TOOLS_JAR:-}" ]]; then
	JAR="$TLA2TOOLS_JAR"
	[[ -f "$JAR" ]] || fail "TLA2TOOLS_JAR does not name a file: $JAR"
else
	command -v curl >/dev/null 2>&1 || fail "curl is required to download the pinned TLA+ tools jar"
	JAR="$WORK/tla2tools.jar"
	if ! curl -fsSL --connect-timeout 10 --max-time 120 --retry 2 "$TLA_URL" -o "$JAR" \
		>"$DIAGNOSTICS_DIR/tla2tools-download.log" 2>&1; then
		cat "$DIAGNOSTICS_DIR/tla2tools-download.log" >&2
		fail "failed to download pinned TLA+ ${TLA_VERSION} tools jar"
	fi
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
{
	printf 'TLA+ version: %s\n' "$TLA_VERSION"
	printf 'TLA+ jar SHA-256: %s\n' "$actual_sha"
	printf 'runner source SHA-256: %s\n' "$(sha256sum "$ROOT/scripts/formal-tlc.sh" | awk '{print $1}')"
} >"$DIAGNOSTICS_DIR/formal-tlc-environment.txt"

run_tlc_command() {
	local name="$1" status log
	shift
	log="$DIAGNOSTICS_DIR/$name.log"
	if "$@" >"$log" 2>&1; then
		status=0
	else
		status=$?
	fi
	cat "$log"
	return "$status"
}

run_tlc_model() {
	local dir="$1" jar="$2" metadir="$3" cfg="$4" module="$5"
	(
		cd "$dir"
		java -jar "$jar" -workers 1 -metadir "$metadir" -config "$cfg" "$module.tla"
	)
}

run_pass() {
	local dir="$1" module="$2" cfg="$3" status log
	log="$DIAGNOSTICS_DIR/$module-$cfg.log"
	if run_tlc_command "$module-$cfg" run_tlc_model \
		"$ROOT/formal/$dir" "$JAR" "$WORK/${module}-${cfg}-states" "$cfg" "$module"; then
		status=0
	else
		status=$?
	fi
	[[ "$status" -eq 0 ]] || fail "$module / $cfg failed (see $log)"
	grep -Fq 'Model checking completed. No error has been found.' "$log" \
		|| fail "$module / $cfg did not report a clean model-check completion (see $log)"
	ok "$module / $cfg"
}

run_expected_violation() {
	local dir="$1" module="$2" cfg="$3" property="$4" status log
	log="$DIAGNOSTICS_DIR/$module-$cfg.log"
	if run_tlc_command "$module-$cfg" run_tlc_model \
		"$ROOT/formal/$dir" "$JAR" "$WORK/${module}-${cfg}-states" "$cfg" "$module"; then
		status=0
	else
		status=$?
	fi
	if [[ "$status" -eq 0 ]]; then
		fail "$module / $cfg unexpectedly passed; expected $property violation (see $log)"
	fi
	if ! grep -Fq "Invariant $property is violated" "$log"; then
		fail "$module / $cfg failed for a reason other than $property (see $log)"
	fi
	ok "$module / $cfg reports expected $property counterexample"
}

# A violated temporal property prints "Temporal properties were violated." with no
# property name (TLC 2.19), so this arm is keyed to the cfg's single PROPERTY.
run_expected_property_violation() {
	local dir="$1" module="$2" cfg="$3" property="$4" status config_file declared_properties log
	config_file="$ROOT/formal/$dir/$cfg"
	[[ -f "$config_file" ]] || fail "$module / $cfg config is missing"
	# This counterexample cfg deliberately uses only one identifier per
	# SPECIFICATION/INVARIANT/PROPERTY line. Fail closed on richer TLC syntax:
	# TLC accepts additional PROPERTY operands on this or following lines.
	declared_properties="$(awk '
		{ sub(/\\\*.*/, "") }
		NF == 0 { next }
		$1 ~ /^CONSTANTS?$/ { next }
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
	log="$DIAGNOSTICS_DIR/$module-$cfg.log"
	if run_tlc_command "$module-$cfg" run_tlc_model \
		"$ROOT/formal/$dir" "$JAR" "$WORK/${module}-${cfg}-states" "$cfg" "$module"; then
		status=0
	else
		status=$?
	fi
	if [[ "$status" -eq 0 ]]; then
		fail "$module / $cfg unexpectedly passed; expected a $property violation (see $log)"
	fi
	if ! grep -Fq "Temporal properties were violated" "$log"; then
		fail "$module / $cfg failed for a reason other than the $property property (see $log)"
	fi
	ok "$module / $cfg reports expected $property property counterexample"
}

run_trace_replay_cases() {
	local cases="$1" mode property config status number=0 log
	[[ -f "$cases" ]] || fail "trace replay case list is missing: $cases"
	[[ -f "$ROOT/formal/wan-log-lock/WanLogRollbackReplay.tla" ]] \
		|| fail "rollback trace replay module is missing"
	while IFS='|' read -r mode property config || [[ -n "${mode:-}${property:-}${config:-}" ]]; do
		[[ -n "${mode:-}" ]] || continue
		[[ -f "$config" ]] || fail "trace replay config is missing: $config"
		number=$((number + 1))
		log="$DIAGNOSTICS_DIR/rollback-replay-$number.log"
		if run_tlc_command "rollback-replay-$number" run_tlc_model \
			"$ROOT/formal/wan-log-lock" "$JAR" "$WORK/rollback-replay-${number}-states" \
			"$config" WanLogRollbackReplay; then
			status=0
		else
			status=$?
		fi
		case "$mode" in
			pass)
				if [[ "$status" -ne 0 ]] || ! grep -Fq "Model checking completed. No error has been found." "$log"; then
					fail "observed rollback trace unexpectedly rejected: $config (see $log)"
				fi
				ok "observed rollback trace passes: $config"
				;;
			reject)
				if [[ "$status" -eq 0 ]] || ! grep -Fq "Invariant $property is violated" "$log"; then
					fail "mutated rollback trace did not violate $property: $config (see $log)"
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
run_pass adaptive-cap AdaptiveCap AdaptiveCap.cfg
run_expected_property_violation adaptive-cap AdaptiveCap AdaptiveCapUnfair.cfg Converges
run_pass adaptive-cap AdaptiveCapClocked AdaptiveCapClockedShort.cfg
run_expected_property_violation adaptive-cap AdaptiveCapClocked AdaptiveCapClockedLong.cfg Converges

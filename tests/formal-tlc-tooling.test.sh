#!/usr/bin/env bash
# Host orchestration only: fake Java does not prove any TLA+ property.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "formal TLC tooling FAIL: $*" >&2; exit 1; }
check_runner_references() {
	local root="$1" runner="$1/scripts/formal-tlc.sh" raw line pending='' kind dir module cfg count=0
	[[ -f "$runner" ]] || { echo "missing runner: $runner" >&2; return 1; }
	while IFS= read -r raw || [[ -n "$raw" ]]; do
		line="$pending$raw"
		pending=''
		if [[ "$line" == *\\ ]]; then
			pending="${line%\\} "
			continue
		fi
		if [[ "$line" =~ ^[[:space:]]*run_(pass|expected_violation|expected_property_violation)([[:space:]]|$) ]]; then
			if [[ ! "$line" =~ ^[[:space:]]*run_(pass|expected_violation|expected_property_violation)[[:space:]]+([a-zA-Z0-9_-]+)[[:space:]]+([A-Za-z0-9_-]+)[[:space:]]+([A-Za-z0-9_.-]+)([[:space:]]|$) ]]; then
				echo "cannot parse TLC runner invocation: $line" >&2
				return 1
			fi
			kind="${BASH_REMATCH[1]}"
			dir="${BASH_REMATCH[2]}"
			module="${BASH_REMATCH[3]}"
			cfg="${BASH_REMATCH[4]}"
			count=$((count + 1))
			[[ -f "$root/formal/$dir/$module.tla" ]] || {
				echo "$kind references missing module: formal/$dir/$module.tla" >&2
				return 1
			}
			[[ -f "$root/formal/$dir/$cfg" ]] || {
				echo "$kind references missing config: formal/$dir/$cfg" >&2
				return 1
			}
		fi
	done < "$runner"
	[[ -z "$pending" ]] || { echo "unterminated TLC runner continuation" >&2; return 1; }
	[[ "$count" -gt 0 ]] || { echo "no TLC invocations found in $runner" >&2; return 1; }
	if grep -Fq 'WanLogRollbackReplay.tla' "$runner"; then
		[[ -f "$root/formal/wan-log-lock/WanLogRollbackReplay.tla" ]] || {
			echo "trace replay runner references missing module: formal/wan-log-lock/WanLogRollbackReplay.tla" >&2
			return 1
		}
	fi
}

# Keep the runner itself as the reference source; no JRE, TLC download, or
# second hand-maintained module/config manifest is needed for this integrity gate.
export TLC_TOOL_LOG="$WORK/calls"
NO_JAVA_PATH="$WORK/path-without-java"
mkdir "$NO_JAVA_PATH"
ln -s "$(command -v grep)" "$NO_JAVA_PATH/grep"
PATH="$NO_JAVA_PATH" check_runner_references "$ROOT" || fail "TLC runner references must exist without Java"
[[ ! -e "$TLC_TOOL_LOG" ]] || fail "reference check must not invoke TLC tooling"
mkdir "$WORK/bin"
for tool in dirname mktemp rm awk grep; do ln -s "$(command -v "$tool")" "$WORK/bin/$tool"; done
# Exercise missing-module and missing-config failures against isolated copies.
# These probes go through the same runner-derived check and never start Java/TLC.
PROBE="$WORK/integrity-probe"
mkdir -p "$PROBE/scripts"
cp -a "$ROOT/formal" "$PROBE/formal"
cp "$ROOT/scripts/formal-tlc.sh" "$PROBE/scripts/formal-tlc.sh"
rm "$PROBE/formal/hostname-dispose/HostnameDispose.tla"
if PATH="$NO_JAVA_PATH" check_runner_references "$PROBE" > "$WORK/missing-module" 2>&1; then
	fail "missing referenced module must fail the integrity check"
fi
grep -q 'missing module: formal/hostname-dispose/HostnameDispose.tla' "$WORK/missing-module" \
	|| fail "missing module diagnostic must name the referenced path"
[[ ! -e "$TLC_TOOL_LOG" ]] || fail "missing-module check must not invoke TLC tooling"
cp "$ROOT/formal/hostname-dispose/HostnameDispose.tla" \
	"$PROBE/formal/hostname-dispose/HostnameDispose.tla"
rm "$PROBE/formal/wan-log-lock/WanLogLock.cfg"
if PATH="$NO_JAVA_PATH" check_runner_references "$PROBE" > "$WORK/missing-config" 2>&1; then
	fail "missing referenced config must fail the integrity check"
fi
grep -q 'missing config: formal/wan-log-lock/WanLogLock.cfg' "$WORK/missing-config" \
	|| fail "missing config diagnostic must name the referenced path"
[[ ! -e "$TLC_TOOL_LOG" ]] || fail "missing-config check must not invoke TLC tooling"
cp "$ROOT/formal/wan-log-lock/WanLogLock.cfg" "$PROBE/formal/wan-log-lock/WanLogLock.cfg"
rm "$PROBE/formal/wan-log-lock/WanLogRollbackReplay.tla"
if PATH="$NO_JAVA_PATH" check_runner_references "$PROBE" > "$WORK/missing-replay-module" 2>&1; then
	fail "missing trace replay module must fail the integrity check"
fi
grep -q 'trace replay runner references missing module: formal/wan-log-lock/WanLogRollbackReplay.tla' \
	"$WORK/missing-replay-module" || fail "missing replay module diagnostic must name its path"
[[ ! -e "$TLC_TOOL_LOG" ]] || fail "missing replay-module check must not invoke TLC tooling"
echo 'formal TLC tooling integrity checks passed (runner references only; no Java/TLC)'

cat > "$WORK/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TLC_TOOL_LOG"
[[ "$*" == *'--connect-timeout 10 --max-time 120 --retry 2'* ]] || exit 91
[[ "${TLC_DOWNLOAD_FAIL:-0}" == 0 ]] || exit 35
while [[ "$#" -gt 0 ]]; do
	if [[ "$1" == -o ]]; then printf fixture > "$2"; break; fi
	shift
done
EOF
chmod +x "$WORK/bin/curl"
if PATH="$WORK/bin" /bin/bash "$ROOT/scripts/formal-tlc.sh" > "$WORK/no-java" 2>&1; then
	fail "missing Java must fail"
fi
grep -q 'java is required; install a JRE' "$WORK/no-java" || fail "missing Java install hint"
[[ ! -e "$TLC_TOOL_LOG" ]] || fail "must preflight Java before any download"
cat > "$WORK/bin/java" <<'EOF'
#!/bin/bash
printf 'java %s\n' "$*" >> "$TLC_TOOL_LOG"
case "$*" in
	*WanLogLockTimedStranding.cfg*) echo 'Invariant NoOrphanStaging is violated'; exit 12 ;;
	*WanLogRollbackAba.cfg*) echo 'Invariant NoOverwriteForeignIntent is violated'; exit 12 ;;
	*HostnameDisposeUngated.cfg*) echo 'Invariant NoLateWrite is violated'; exit 12 ;;
	*WanLogRollbackRevisionUnfair.cfg*) echo 'Error: Temporal properties were violated.'; exit 13 ;;
	*WanLogRollbackOutcomesValueOnly.cfg*)
		echo 'Invariant NoRestoreAfterNewerIntent is violated'; exit 12 ;;
	*WanLogRollbackOutcomesWrongRestore.cfg*)
		echo 'Invariant RestoreValueIsPrevious is violated'; exit 12 ;;
	*WanLogRollbackOutcomesValueOnlyDisable.cfg*)
		echo 'Invariant NoRestoreAfterNewerIntent is violated'; exit 12 ;;
	*WanLogRollbackOutcomesWrongRestoreDisable.cfg*)
		echo 'Invariant RestoreValueIsPrevious is violated'; exit 12 ;;
	*WanLogRollbackReplay.tla*)
		case "$*" in *replay-reject.cfg*) echo 'Invariant NoInvalidObservation is violated'; exit 12 ;; esac
		echo 'Model checking completed. No error has been found.'; exit 0 ;;
esac
EOF
cat > "$WORK/bin/sha256sum" <<'EOF'
#!/bin/bash
printf '%s  %s\n' 936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88 "$1"
EOF
chmod +x "$WORK/bin/java" "$WORK/bin/sha256sum"
if PATH="$WORK/bin" TLC_DOWNLOAD_FAIL=1 /bin/bash "$ROOT/scripts/formal-tlc.sh" > "$WORK/download-fail" 2>&1; then
	fail "download failure must fail"
fi
! grep -q '^java ' "$TLC_TOOL_LOG" || fail "failed download must not run Java"
: > "$TLC_TOOL_LOG"
PATH="$WORK/bin" /bin/bash "$ROOT/scripts/formal-tlc.sh" > "$WORK/download" 2>&1
[[ "$(grep -c '^java ' "$TLC_TOOL_LOG")" == 16 ]] || fail "expected sixteen model invocations"
: > "$TLC_TOOL_LOG"
printf fixture > "$WORK/cached.jar"
PATH="$WORK/bin" TLA2TOOLS_JAR="$WORK/cached.jar" /bin/bash "$ROOT/scripts/formal-tlc.sh" > "$WORK/cached" 2>&1
[[ "$(grep -c '^java ' "$TLC_TOOL_LOG")" == 16 ]] || fail "cached jar expected sixteen invocations"
! grep -q 'connect-timeout' "$TLC_TOOL_LOG" || fail "cached jar must not download"

# The generic temporal-failure message is attributed only to the one property
# actually declared in the selected cfg. Use an isolated runner root so these
# fixtures never mutate the checked-in configuration.
PROBE="$WORK/property-probe"
mkdir -p "$PROBE/scripts" "$PROBE/formal/wan-log-lock" "$PROBE/formal/hostname-dispose"
cp "$ROOT/scripts/formal-tlc.sh" "$PROBE/scripts/formal-tlc.sh"
cp "$ROOT/formal/wan-log-lock/WanLogRollbackRevisionUnfair.cfg" \
	"$PROBE/formal/wan-log-lock/WanLogRollbackRevisionUnfair.cfg"
expect_bad_property_cfg() {
	local label="$1"
	: > "$TLC_TOOL_LOG"
	if PATH="$WORK/bin" TLA2TOOLS_JAR="$WORK/cached.jar" \
		/bin/bash "$PROBE/scripts/formal-tlc.sh" > "$WORK/$label" 2>&1; then
		fail "$label property configuration must fail"
	fi
	grep -q 'must declare exactly PROPERTY RestoreLandsWithoutForeignCommit' \
		"$WORK/$label" || fail "$label must report the mismatched property declaration"
	! grep -Fq 'WanLogRollbackRevisionUnfair.cfg' "$TLC_TOOL_LOG" \
		|| fail "$label must reject the cfg before attributing its temporal failure"
}
: > "$TLC_TOOL_LOG"
if ! PATH="$WORK/bin" TLA2TOOLS_JAR="$WORK/cached.jar" \
	/bin/bash "$PROBE/scripts/formal-tlc.sh" > "$WORK/property-valid" 2>&1; then
	cat "$WORK/property-valid" >&2
	fail "single expected PROPERTY declaration must pass"
fi
valid_invocations="$(grep -c '^java ' "$TLC_TOOL_LOG")"
if [[ "$valid_invocations" != 16 ]]; then
	cat "$TLC_TOOL_LOG" >&2
	fail "valid property config must run all sixteen models (ran $valid_invocations)"
fi
printf 'SPECIFICATION SpecNoFairness\nINVARIANT TypeOK\n' \
	> "$PROBE/formal/wan-log-lock/WanLogRollbackRevisionUnfair.cfg"
expect_bad_property_cfg property-missing
printf 'SPECIFICATION SpecNoFairness\nINVARIANT TypeOK\nPROPERTY OtherProperty\n' \
	> "$PROBE/formal/wan-log-lock/WanLogRollbackRevisionUnfair.cfg"
expect_bad_property_cfg property-different
printf 'SPECIFICATION SpecNoFairness\nINVARIANT TypeOK\nPROPERTY RestoreLandsWithoutForeignCommit\nPROPERTY RollbackCompletes\n' \
	> "$PROBE/formal/wan-log-lock/WanLogRollbackRevisionUnfair.cfg"
expect_bad_property_cfg property-additional
printf 'SPECIFICATION SpecNoFairness\nINVARIANT TypeOK\nPROPERTY RestoreLandsWithoutForeignCommit RollbackCompletes\n' \
	> "$PROBE/formal/wan-log-lock/WanLogRollbackRevisionUnfair.cfg"
expect_bad_property_cfg property-same-line
printf 'SPECIFICATION SpecNoFairness\nINVARIANT TypeOK\nPROPERTY RestoreLandsWithoutForeignCommit\n  RollbackCompletes\n' \
	> "$PROBE/formal/wan-log-lock/WanLogRollbackRevisionUnfair.cfg"
expect_bad_property_cfg property-continuation
printf 'SPECIFICATION SpecNoFairness\nINVARIANT TypeOK\nPROPERTY RestoreLandsWithoutForeignCommit\nPROPERTIES RollbackCompletes\n' \
	> "$PROBE/formal/wan-log-lock/WanLogRollbackRevisionUnfair.cfg"
expect_bad_property_cfg property-plural

# The optional observation-replay mode shares the runner's verified jar and
# expects the named invariant from a rejected mutation trace.
cp "$ROOT/formal/wan-log-lock/WanLogRollbackReplay.tla" \
	"$PROBE/formal/wan-log-lock/WanLogRollbackReplay.tla"
: > "$WORK/replay-pass.cfg"
: > "$WORK/replay-reject.cfg"
printf 'pass|-|%s\nreject|NoInvalidObservation|%s\n' \
	"$WORK/replay-pass.cfg" "$WORK/replay-reject.cfg" > "$WORK/replay-cases"
: > "$TLC_TOOL_LOG"
if ! PATH="$WORK/bin" TLA2TOOLS_JAR="$WORK/cached.jar" \
	FWLIVE_TLC_REPLAY_CASES="$WORK/replay-cases" \
	/bin/bash "$PROBE/scripts/formal-tlc.sh" > "$WORK/replay-runner" 2>&1; then
	cat "$WORK/replay-runner" >&2
	fail "replay runner mode must accept the valid trace and expected mutation"
fi
[[ "$(grep -c '^java ' "$TLC_TOOL_LOG")" == 2 ]] \
	|| fail "replay runner mode must invoke TLC exactly once per trace case"
grep -q 'mutated rollback trace rejected by NoInvalidObservation' "$WORK/replay-runner" \
	|| fail "replay runner mode must attribute the expected invariant violation"

echo 'formal TLC tooling host tests passed (runner integrity, transfer/Java gates, property attribution, replay mode)'

#!/usr/bin/env bash
# Host orchestration only: fake Java does not prove any TLA+ property.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "formal TLC tooling FAIL: $*" >&2; exit 1; }
mkdir "$WORK/bin"
for tool in dirname mktemp rm awk grep; do ln -s "$(command -v "$tool")" "$WORK/bin/$tool"; done
export TLC_TOOL_LOG="$WORK/calls"
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
[[ "$(grep -c '^java ' "$TLC_TOOL_LOG")" == 7 ]] || fail "expected seven model invocations"
: > "$TLC_TOOL_LOG"
printf fixture > "$WORK/cached.jar"
PATH="$WORK/bin" TLA2TOOLS_JAR="$WORK/cached.jar" /bin/bash "$ROOT/scripts/formal-tlc.sh" > "$WORK/cached" 2>&1
[[ "$(grep -c '^java ' "$TLC_TOOL_LOG")" == 7 ]] || fail "cached jar expected seven invocations"
! grep -q 'connect-timeout' "$TLC_TOOL_LOG" || fail "cached jar must not download"
echo 'formal TLC tooling host tests passed (stubbed transfers and Java only)'

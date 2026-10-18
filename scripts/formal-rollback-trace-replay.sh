#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Bounded shell-observation replay; invokes the pinned formal TLC runner
# separately from its default model pass.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [[ -n "${FWLIVE_ROLLBACK_TRACE_DIAGNOSTICS_DIR:-}" ]]; then
	DIAGNOSTICS_DIR="$FWLIVE_ROLLBACK_TRACE_DIAGNOSTICS_DIR"
	case "$DIAGNOSTICS_DIR" in
		/*) ;;
		*) DIAGNOSTICS_DIR="$PWD/$DIAGNOSTICS_DIR" ;;
	esac
	mkdir -p "$DIAGNOSTICS_DIR"
else
	DIAGNOSTICS_DIR="$WORK/diagnostics"
	mkdir -p "$DIAGNOSTICS_DIR"
fi
CAPTURE="$ROOT/tests/fwlive-rollback-trace-capture.sh"
PROJECT="$ROOT/scripts/formal-rollback-trace-project.py"
MUTATE="$ROOT/tests/mutate-wan-log-noop-generation.py"
LOGGING_SH="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh"
{
	printf 'rollback trace pilot checkout HEAD: %s\n' "$(git -C "$ROOT" rev-parse HEAD)"
	python3 --version
	java -version 2>&1
	printf 'shell path: %s\n' "$(command -v sh)"
	flock --version 2>&1 || true
} >"$DIAGNOSTICS_DIR/replay-environment.txt"
for source in \
	openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh \
	formal/wan-log-lock/WanLogRollbackOutcomes.tla \
	formal/wan-log-lock/WanLogRollbackReplay.tla \
	tests/fwlive-rollback-trace-capture.sh \
	scripts/formal-rollback-trace-project.py \
	tests/lib/rollback-trace-cases.py \
	tests/mutate-wan-log-noop-generation.py \
	scripts/formal-rollback-trace-replay.sh; do
	printf 'rollback trace pilot source %s: %s\n' "$source" "$(git -C "$ROOT" hash-object "$ROOT/$source")" \
		>>"$DIAGNOSTICS_DIR/replay-environment.txt"
done
cat "$DIAGNOSTICS_DIR/replay-environment.txt"

SEED="${FWLIVE_ROLLBACK_TRACE_SEED:-1322}"
python3 "$ROOT/tests/lib/rollback-trace-cases.py" --seed "$SEED" \
	> "$DIAGNOSTICS_DIR/input-cases"
printf 'rollback generated-schedule seed: %s\n' "$SEED" >> "$DIAGNOSTICS_DIR/replay-environment.txt"
sha256sum "$DIAGNOSTICS_DIR/input-cases" >> "$DIAGNOSTICS_DIR/replay-environment.txt"
: > "$DIAGNOSTICS_DIR/cases"
while IFS='|' read -r name scenario intent initial schedule; do
	[[ "$schedule" != - ]] || schedule=''
	"$CAPTURE" "$LOGGING_SH" "$scenario" "$DIAGNOSTICS_DIR/$name" "$intent" "$initial" "$schedule" \
		>"$DIAGNOSTICS_DIR/$name.capture"
	python3 "$PROJECT" "$DIAGNOSTICS_DIR/$name/observations.tsv" \
		"$DIAGNOSTICS_DIR/$name.cfg" >"$DIAGNOSTICS_DIR/$name.projection" 2>&1
	printf 'pass|-|%s\n' "$DIAGNOSTICS_DIR/$name.cfg" >> "$DIAGNOSTICS_DIR/cases"
done < "$DIAGNOSTICS_DIR/input-cases"

# Value-only guard mutation: the real ABA observations must not admit the
# rollback action sequence predicted by the broken guard.
python3 "$PROJECT" "$DIAGNOSTICS_DIR/enable-unset-aba/observations.tsv" "$DIAGNOSTICS_DIR/aba-value-only.cfg" \
	--guard-mode valueOnly >"$DIAGNOSTICS_DIR/aba-value-only.projection"

# Mutate only a disposable copy of the shell helper. The observed no-op trace
# has unchanged committed value and no generation bump; the model requires one.
python3 "$MUTATE" "$LOGGING_SH" "$DIAGNOSTICS_DIR/broken-noop-helper.sh"
"$CAPTURE" "$DIAGNOSTICS_DIR/broken-noop-helper.sh" noop "$DIAGNOSTICS_DIR/noop-broken" \
	>"$DIAGNOSTICS_DIR/noop-broken.capture"
python3 "$PROJECT" "$DIAGNOSTICS_DIR/noop-broken/observations.tsv" \
	"$DIAGNOSTICS_DIR/noop-broken.cfg" >"$DIAGNOSTICS_DIR/noop-broken.projection"

# Failure-path observation mutation: falsely claim the failed restore commit
# successfully restored the previous value. The existing model must reject it.
python3 - "$DIAGNOSTICS_DIR/enable-unset-commit.cfg" "$DIAGNOSTICS_DIR/commit-wrong-value.cfg" <<'PYMUTATE'
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
step = re.search(r'Step([0-9]+) = "RestoreCommitFailure"', text)
if step is None:
    raise SystemExit('restore commit failure mutation site drift')
text, count = re.subn(rf'Value{step[1]} = "on"', f'Value{step[1]} = "unset"', text)
if count != 1:
    raise SystemExit('restore commit failure checkpoint drift')
Path(sys.argv[2]).write_text(text)
PYMUTATE
cat >> "$DIAGNOSTICS_DIR/cases" <<EOF
reject|NoInvalidObservation|$DIAGNOSTICS_DIR/aba-value-only.cfg
reject|NoInvalidObservation|$DIAGNOSTICS_DIR/noop-broken.cfg
reject|NoInvalidObservation|$DIAGNOSTICS_DIR/commit-wrong-value.cfg
EOF
FWLIVE_TLC_DIAGNOSTICS_DIR="$DIAGNOSTICS_DIR/tlc" \
	FWLIVE_TLC_REPLAY_CASES="$DIAGNOSTICS_DIR/cases" "$ROOT/scripts/formal-tlc.sh"

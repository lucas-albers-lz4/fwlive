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
} >"$DIAGNOSTICS_DIR/replay-environment.txt"
for source in \
	openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh \
	formal/wan-log-lock/WanLogRollbackOutcomes.tla \
	formal/wan-log-lock/WanLogRollbackReplay.tla \
	tests/fwlive-rollback-trace-capture.sh \
	scripts/formal-rollback-trace-project.py; do
	printf 'rollback trace pilot source %s: %s\n' "$source" "$(git -C "$ROOT" hash-object "$ROOT/$source")" \
		>>"$DIAGNOSTICS_DIR/replay-environment.txt"
done
cat "$DIAGNOSTICS_DIR/replay-environment.txt"

for scenario in success aba noop failed refusal; do
	"$CAPTURE" "$LOGGING_SH" "$scenario" "$DIAGNOSTICS_DIR/$scenario" \
		>"$DIAGNOSTICS_DIR/$scenario.capture"
	python3 "$PROJECT" "$DIAGNOSTICS_DIR/$scenario/observations.tsv" \
		"$DIAGNOSTICS_DIR/$scenario.cfg" >"$DIAGNOSTICS_DIR/$scenario.projection"
done

# Value-only guard mutation: the real ABA observations must not admit the
# rollback action sequence predicted by the broken guard.
python3 "$PROJECT" "$DIAGNOSTICS_DIR/aba/observations.tsv" "$DIAGNOSTICS_DIR/aba-value-only.cfg" \
	--guard-mode valueOnly >"$DIAGNOSTICS_DIR/aba-value-only.projection"

# Mutate only a disposable copy of the shell helper. The observed no-op trace
# has unchanged committed value and no generation bump; the model requires one.
python3 "$MUTATE" "$LOGGING_SH" "$DIAGNOSTICS_DIR/broken-noop-helper.sh"
"$CAPTURE" "$DIAGNOSTICS_DIR/broken-noop-helper.sh" noop "$DIAGNOSTICS_DIR/noop-broken" \
	>"$DIAGNOSTICS_DIR/noop-broken.capture"
python3 "$PROJECT" "$DIAGNOSTICS_DIR/noop-broken/observations.tsv" \
	"$DIAGNOSTICS_DIR/noop-broken.cfg" >"$DIAGNOSTICS_DIR/noop-broken.projection"

cat > "$DIAGNOSTICS_DIR/cases" <<EOF
pass|-|$DIAGNOSTICS_DIR/success.cfg
pass|-|$DIAGNOSTICS_DIR/aba.cfg
pass|-|$DIAGNOSTICS_DIR/noop.cfg
pass|-|$DIAGNOSTICS_DIR/failed.cfg
pass|-|$DIAGNOSTICS_DIR/refusal.cfg
reject|NoInvalidObservation|$DIAGNOSTICS_DIR/aba-value-only.cfg
reject|NoInvalidObservation|$DIAGNOSTICS_DIR/noop-broken.cfg
EOF
FWLIVE_TLC_DIAGNOSTICS_DIR="$DIAGNOSTICS_DIR/tlc" \
	FWLIVE_TLC_REPLAY_CASES="$DIAGNOSTICS_DIR/cases" "$ROOT/scripts/formal-tlc.sh"

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Manual-only bounded shell-observation replay; uses the pinned formal TLC runner.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CAPTURE="$ROOT/tests/fwlive-rollback-trace-capture.sh"
PROJECT="$ROOT/scripts/formal-rollback-trace-project.py"
MUTATE="$ROOT/tests/mutate-wan-log-noop-generation.py"
LOGGING_SH="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh"
printf 'rollback trace pilot checkout HEAD: %s\n' "$(git -C "$ROOT" rev-parse HEAD)"
for source in \
	openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh \
	formal/wan-log-lock/WanLogRollbackOutcomes.tla \
	formal/wan-log-lock/WanLogRollbackReplay.tla \
	tests/fwlive-rollback-trace-capture.sh \
	scripts/formal-rollback-trace-project.py; do
	printf 'rollback trace pilot source %s: %s\n' "$source" "$(git -C "$ROOT" hash-object "$ROOT/$source")"
done

for scenario in success aba noop failed refusal; do
	"$CAPTURE" "$LOGGING_SH" "$scenario" "$WORK/$scenario" > "$WORK/$scenario.capture"
	python3 "$PROJECT" "$WORK/$scenario/observations.tsv" "$WORK/$scenario.cfg" \
		> "$WORK/$scenario.projection"
done

# Value-only guard mutation: the real ABA observations must not admit the
# rollback action sequence predicted by the broken guard.
python3 "$PROJECT" "$WORK/aba/observations.tsv" "$WORK/aba-value-only.cfg" \
	--guard-mode valueOnly > "$WORK/aba-value-only.projection"

# Mutate only a disposable copy of the shell helper. The observed no-op trace
# has unchanged committed value and no generation bump; the model requires one.
python3 "$MUTATE" "$LOGGING_SH" "$WORK/broken-noop-helper.sh"
"$CAPTURE" "$WORK/broken-noop-helper.sh" noop "$WORK/noop-broken" > "$WORK/noop-broken.capture"
python3 "$PROJECT" "$WORK/noop-broken/observations.tsv" "$WORK/noop-broken.cfg" \
	> "$WORK/noop-broken.projection"

cat > "$WORK/cases" <<EOF
pass|-|$WORK/success.cfg
pass|-|$WORK/aba.cfg
pass|-|$WORK/noop.cfg
pass|-|$WORK/failed.cfg
pass|-|$WORK/refusal.cfg
reject|NoInvalidObservation|$WORK/aba-value-only.cfg
reject|NoInvalidObservation|$WORK/noop-broken.cfg
EOF
FWLIVE_TLC_REPLAY_CASES="$WORK/cases" "$ROOT/scripts/formal-tlc.sh"

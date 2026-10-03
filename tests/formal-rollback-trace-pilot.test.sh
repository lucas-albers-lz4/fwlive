#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Host-only capture/projection integrity checks. This deliberately does not run TLC.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CAPTURE="$ROOT/tests/fwlive-rollback-trace-capture.sh"
PROJECT="$ROOT/scripts/formal-rollback-trace-project.py"
LOGGING_SH="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh"
fail() { echo "rollback trace pilot FAIL: $*" >&2; exit 1; }

for scenario in success aba noop failed refusal; do
	"$CAPTURE" "$LOGGING_SH" "$scenario" "$WORK/$scenario" > "$WORK/$scenario.out"
	python3 "$PROJECT" "$WORK/$scenario/observations.tsv" "$WORK/$scenario.cfg" \
		> "$WORK/$scenario.projected"
done

cat > "$WORK/nonzero-return-helper.sh" <<'EOF'
enable_wan_logging() {
	printf '{"changed":false}\n'
	return 37
}
EOF
"$CAPTURE" "$WORK/nonzero-return-helper.sh" success "$WORK/return-fail" \
	> "$WORK/return-fail.out"
grep -q 'SNAP|success|primary|[0-9][0-9]*|return:37|enable|unset|0' \
	"$WORK/return-fail/observations.tsv" \
	|| fail "a nonzero helper return must be captured without aborting the runner"

grep -q 'UCI|success|primary|[0-9][0-9]*|enable|commit firewall|0|unset|1|1|1' \
	"$WORK/success/observations.tsv" || fail "successful trace must capture real primary commit outcome/state"
grep -q 'FLOCK|success|primary|[0-9][0-9]*|enable|-n 9|0|1|1' \
	"$WORK/success/observations.tsv" || fail "success trace must capture rollback lock acquisition"
grep -q 'UCI|aba|secondary|[0-9][0-9]*|disable|commit firewall|0|1|unset|2|2' \
	"$WORK/aba/observations.tsv" || fail "ABA trace must observe the cooperating disable commit"
grep -q 'UCI|aba|secondary|[0-9][0-9]*|enable|commit firewall|0|unset|1|3|3' \
	"$WORK/aba/observations.tsv" || fail "ABA trace must observe the cooperating enable commit"
grep -q 'SNAP|noop|secondary|[0-9][0-9]*|return:0|enable|1|2' \
	"$WORK/noop/observations.tsv" || fail "no-op trace must observe unchanged value and advanced generation"
grep -Fq '"changed":false' "$WORK/noop/observations.tsv" \
	|| fail "no-op trace must capture the helper's JSON result"
grep -q 'UCI|failed|secondary|[0-9][0-9]*|disable|commit firewall|1|1|1|2|2' \
	"$WORK/failed/observations.tsv" || fail "failed-intent trace must capture the command failure and retained value"
grep -Fq '|enable|0|1|1|firewall.@zone[0].log_limit' \
	"$WORK/refusal/observations.tsv" || fail "refusal trace must capture the observed foreign staged option"
grep -q 'RestorePendingRefusal' "$WORK/refusal.projected" \
	|| fail "pending-change refusal must project to its modeled terminal outcome"

grep -q 'PrimaryCommit -> ReloadFails -> ReacquireSuccess -> BeginRestore -> RestoreCommitSuccess' \
	"$WORK/success.projected" || fail "success observations did not project through the expected model actions"
grep -q 'PrimaryCommit -> LaterCommit -> LaterCommit -> ReloadFails -> ReacquireSuccess -> SkipNewerIntent' \
	"$WORK/aba.projected" || fail "ABA observations did not project through the expected model actions"
grep -q 'PrimaryCommit -> LaterNoOp -> ReloadFails -> ReacquireSuccess -> SkipNewerIntent' \
	"$WORK/noop.projected" || fail "no-op observations did not project through the expected model actions"
grep -q 'PrimaryCommit -> LaterFailedAttempt -> ReloadFails -> ReacquireSuccess -> SkipNewerIntent' \
	"$WORK/failed.projected" || fail "failed-attempt observations did not project through the expected model actions"

# Disposable source mutation: suppress only the actual no-op generation bump.
python3 "$ROOT/tests/mutate-wan-log-noop-generation.py" "$LOGGING_SH" \
	"$WORK/broken-noop-helper.sh"
"$CAPTURE" "$WORK/broken-noop-helper.sh" noop "$WORK/noop-broken" > "$WORK/noop-broken.out"
python3 "$PROJECT" "$WORK/noop-broken/observations.tsv" "$WORK/noop-broken.cfg" \
	> "$WORK/noop-broken.projected"
grep -q 'Step2 = "LaterNoOp"' "$WORK/noop-broken.cfg" \
	|| fail "broken no-op fixture must remain classified from observed call facts"
grep -q 'Generation2 = 1' "$WORK/noop-broken.cfg" \
	|| fail "broken no-op fixture must preserve its observed missing generation bump"

echo 'rollback trace pilot host checks passed (real helper capture/projection; TLC remains manual-only)'

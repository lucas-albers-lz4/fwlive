#!/usr/bin/env bash
# Host-only integer induction; no generated proof output is shipped.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="${FWLIVE_INDUCTION_DIAGNOSTICS_DIR:-$WORK/evidence}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
for tool in java timeout sha256sum tar awk; do command -v "$tool" >/dev/null; done
JAVA_MAJOR="$(java -XshowSettings:properties -version 2>&1 | awk '/java.specification.version =/ { print $3 }')"
[[ "$JAVA_MAJOR" =~ ^[0-9]+$ && "$JAVA_MAJOR" -ge 21 ]] \
	|| { echo 'Java 21 or newer must be selected on PATH' >&2; exit 1; }
APALACHE_VERSION=0.62.1
APALACHE_SHA256=38202a8c4ebeb3ab73e0fe5a7e4bb948442d46ad5de8a7fb45c9e5cac2beb2a6
APALACHE_JAR_SHA256=880c0b2b72354816f12e9a9755829f2907071e9a181ffea1937954c23d54739d
ARCHIVE="${FWLIVE_APALACHE_ARCHIVE:-$WORK/apalache.tgz}"
if [[ -z "${FWLIVE_APALACHE_ARCHIVE:-}" ]]; then
	curl -fsSL --connect-timeout 10 --max-time 180 --retry 2 \
		"https://github.com/apalache-mc/apalache/releases/download/v${APALACHE_VERSION}/apalache.tgz" -o "$ARCHIVE"
fi
[[ "$(sha256sum "$ARCHIVE" | awk '{print $1}')" == "$APALACHE_SHA256" ]] \
	|| { echo 'Apalache archive checksum mismatch' >&2; exit 1; }
tar -xzf "$ARCHIVE" -C "$WORK"
BACKEND="$WORK/apalache/bin/apalache-mc"
[[ "$(sha256sum "$WORK/apalache/lib/apalache.jar" | awk '{print $1}')" == "$APALACHE_JAR_SHA256" ]] \
	|| { echo 'Apalache jar checksum mismatch' >&2; exit 1; }
{
	printf 'Apalache version: %s\narchive SHA-256: %s\njar SHA-256: %s\n' \
		"$APALACHE_VERSION" "$APALACHE_SHA256" "$APALACHE_JAR_SHA256"
	git -C "$ROOT" rev-parse HEAD
	java -version 2>&1
	sha256sum "$ROOT/scripts/formal-induction.sh" \
		"$ROOT/formal/wan-log-lock/WanLogRollbackOutcomes.tla" \
		"$ROOT/formal/wan-log-lock/WanLogRollbackInduction.tla"
} | tee "$OUT/environment.txt"
cd "$ROOT/formal/wan-log-lock"
run_obligation() {
	local name="$1" constants="$2" init="$3" invariant="$4" length="$5" expected="$6" status=0
	local log="$OUT/$name.log"
	printf '%s: cinit=%s init=%s next=HistoryNext inv=%s length=%s expected=%s\n' \
		"$name" "$constants" "$init" "$invariant" "$length" "$expected" | tee -a "$OUT/obligations.txt"
	timeout --kill-after=5s 120s "$BACKEND" "--out-dir=$OUT/$name" check \
		"--cinit=$constants" "--init=$init" --next=HistoryNext "--inv=$invariant" \
		"--length=$length" WanLogRollbackInduction.tla >"$log" 2>&1 || status=$?
	if [[ "$expected" == pass && "$status" == 0 ]] && grep -q '^EXITCODE: OK$' "$log"; then
		printf 'induction OK: %s\n' "$name"
	elif [[ "$expected" == reject && "$status" == 12 ]] \
		&& grep -q 'State 1: state invariant .* violated' "$log" \
		&& grep -q '^EXITCODE: ERROR (12)$' "$log"; then
		printf 'induction OK: %s rejected by invariant\n' "$name"
	else
		cat "$log" >&2
		printf 'induction FAIL: %s (status %s)\n' "$name" "$status" >&2
		return 1
	fi
}
: > "$OUT/obligations.txt"
for contract in Unbounded Deployed; do
	run_obligation "$contract-init" "${contract}Constants" HistoryInit IndInv 0 pass
	run_obligation "$contract-step" "${contract}Constants" IndInv IndInv 1 pass
	run_obligation "$contract-safety" "${contract}Constants" IndInv Safety 0 pass
done
run_obligation deployed-limit DeployedConstants AtLimit StillAtLimit 1 pass
run_obligation weakened-guard BrokenConstants IndInv IndInv 1 reject
printf 'induction OK: seven obligations and weakened-guard rejection\n'

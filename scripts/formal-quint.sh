#!/usr/bin/env bash
# Host-only Quint pilot. Tool archives are verified before extraction/execution.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="${FWLIVE_QUINT_DIAGNOSTICS_DIR:-$WORK/evidence}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
QUINT="$ROOT/node_modules/.bin/quint"
[[ -x "$QUINT" ]] || { echo 'Run npm ci first (pinned Quint required)' >&2; exit 1; }
[[ "$("$QUINT" --version)" == 0.33.0 ]] || { echo 'Unexpected Quint version' >&2; exit 1; }
command -v java >/dev/null
JAVA_MAJOR="$(java -XshowSettings:properties -version 2>&1 | awk '/java.specification.version =/ { print $3 }')"
[[ "$JAVA_MAJOR" =~ ^[0-9]+$ && "$JAVA_MAJOR" -ge 21 ]] \
	|| { echo 'Java 21 or newer must be selected on PATH' >&2; exit 1; }
command -v timeout >/dev/null
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
export QUINT_HOME="$WORK/quint"
mkdir -p "$QUINT_HOME/apalache-dist-$APALACHE_VERSION"
tar -xzf "$ARCHIVE" -C "$QUINT_HOME/apalache-dist-$APALACHE_VERSION"
[[ "$(sha256sum "$QUINT_HOME/apalache-dist-$APALACHE_VERSION/apalache/lib/apalache.jar" | awk '{print $1}')" == "$APALACHE_JAR_SHA256" ]] \
	|| { echo 'Apalache jar checksum mismatch' >&2; exit 1; }
printf '{"maxHeap":"-Xmx1G","stackSize":"-Xss4m","workers":"1"}\n' > "$OUT/tlc.json"
# Bind-and-release finds a local port; each CLI owns and cleans its backend.
# A port race is an execution failure, never permission to use unverified output.
PORT="$(node -e 'const s=require("node:net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
# Keep generated backend files out of the checkout.
cd "$WORK"
timeout --kill-after=5s 120s "$QUINT" verify "$ROOT/formal/poll-coordinator/poll-coordinator.qnt" \
	--backend tlc --apalache-version "$APALACHE_VERSION" --server-endpoint "localhost:$PORT" \
	--step checkStep --invariant invariant --tlc-config "$OUT/tlc.json" --verbosity 3 \
	> "$OUT/model-check.log" 2>&1 || { cat "$OUT/model-check.log" >&2; exit 1; }
node "$ROOT/scripts/formal-quint-replay.js" "$OUT"

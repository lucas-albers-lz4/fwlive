#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Count PATH-shim-observable external execs on the fwlive poll hot path (#308).
#
# Accounting rules:
# - Only commands reached through shims in SHIM_CMDS are counted.
# - Builtin subshell forks (raw=$(…), $(cat <<'AWK') as a subshell) are NOT
#   observed unless they exec a shimmed binary (the heredoc's `cat` is counted).
# - The report separates production-path execs from harness-only artifacts.
#
# Usage:
#   ./scripts/fork-census.sh
#   ./scripts/fork-census.sh --fixture tests/fixtures/logread-2000.json
#   ./scripts/fork-census.sh --expect-filter N --expect-poll N
# Relative --fixture paths resolve against the repo root (script location), not cwd.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER_SH="${ROOT}/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-log-filter.sh"
CLASSIFY_SH="${ROOT}/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.sh"
LOGGING_SH="${ROOT}/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh"
RPCD="${ROOT}/openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive"
FIXTURE="${ROOT}/tests/fixtures/logread-mixed.json"
EXPECT_FILTER=""
EXPECT_POLL=""
SKIP_PARSE=0

# dirname is required (#308 Phase 0a); jq is stub-accounted when used by the harness.
# jshn/sed are device-only (#308 F2 / #310): poll_lines_from_input sources a fixed
# /usr/share/libubox/jshn.sh path, so a PATH stub alone aborts under set -e on host.
# Do not pretend host can exercise that branch — leave jshn off PATH here.
SHIM_CMDS=(cat jsonfilter awk dirname jq sed ubus)

usage() {
	sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--fixture) FIXTURE="${2:?}"; shift 2 ;;
		--expect-filter) EXPECT_FILTER="${2:?}"; shift 2 ;;
		--expect-poll) EXPECT_POLL="${2:?}"; shift 2 ;;
		--skip-parse) SKIP_PARSE=1; shift ;;
		-h|--help) usage 0 ;;
		*) echo "unknown arg: $1" >&2; usage 1 ;;
	esac
done

# Resolve relative fixture paths against ROOT before the existence check.
if [[ "$FIXTURE" != /* ]]; then
	FIXTURE="${ROOT}/${FIXTURE}"
fi

if [[ ! -f "$FIXTURE" ]]; then
	echo "fixture not found: $FIXTURE" >&2
	exit 1
fi
if [[ ! -f "$FILTER_SH" || ! -f "$RPCD" ]]; then
	echo "missing filter or rpcd script under openwrt-feed/" >&2
	exit 1
fi

WORKDIR="$(mktemp -d)"
SHIM_DIR="${WORKDIR}/shim"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$SHIM_DIR"

resolve_real() {
	local name="$1"
	local p
	# Prefer absolute paths so shims do not recurse into SHIM_DIR.
	for p in "/usr/bin/${name}" "/bin/${name}" "/usr/sbin/${name}"; do
		if [[ -x "$p" ]]; then
			printf '%s' "$p"
			return 0
		fi
	done
	# Fall back via env -i PATH to avoid our own shims.
	p="$(env -i PATH="/usr/bin:/bin:/usr/sbin" command -v "$name" 2>/dev/null || true)"
	if [[ -n "$p" && -x "$p" ]]; then
		printf '%s' "$p"
		return 0
	fi
	printf '%s' "/bin/false"
}

install_passthrough_shim() {
	local name="$1"
	local tally="$2"
	local real
	real="$(resolve_real "$name")"
	cat >"${SHIM_DIR}/${name}" <<EOF
#!/bin/sh
printf '%s\\n' "$name" >>"$tally"
exec "$real" "\$@"
EOF
	chmod +x "${SHIM_DIR}/${name}"
}

install_jsonfilter_stub() {
	local tally="$1"
	local stub_js="${WORKDIR}/jsonfilter-stub.js"
	# Host stand-in for OpenWrt jsonfilter (same shape as tests/fwlive-shell-filter.test.js).
	cat >"$stub_js" <<'EOF'
#!/usr/bin/env node
'use strict';
const fs = require('fs');
let input = '';
let expr = '';
let usedS = false;
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
	if (argv[i] === '-s' && i + 1 < argv.length) { input = argv[++i]; usedS = true; }
	else if (argv[i] === '-e' && i + 1 < argv.length) expr = argv[++i];
}
if (!usedS) input = fs.readFileSync(0, 'utf8');
if (expr !== '@.log[*]') process.exit(1);
let data;
try { data = JSON.parse(input); } catch (e) { process.exit(1); }
const log = (data && Array.isArray(data.log)) ? data.log : [];
for (const e of log) process.stdout.write(JSON.stringify(e) + '\n');
EOF
	chmod +x "$stub_js"
	# Count in the shell wrapper so tally is recorded before node starts.
	cat >"${SHIM_DIR}/jsonfilter" <<EOF
#!/bin/sh
printf '%s\\n' "jsonfilter" >>"$tally"
NODE_BIN=\$(command -v node || command -v nodejs || true)
if [ -z "\$NODE_BIN" ]; then
	echo "fork-census: node required for jsonfilter stub" >&2
	exit 1
fi
exec "\$NODE_BIN" "$stub_js" "\$@"
EOF
	chmod +x "${SHIM_DIR}/jsonfilter"
}

install_ubus_stub() {
	local fixture="$1"
	local tally="$2"
	# Production: ubus is one IPC exec. Host stub cats the fixture (harness artifact).
	cat >"${SHIM_DIR}/ubus" <<EOF
#!/bin/sh
printf '%s\\n' "ubus" >>"$tally"
if [ "\$1" = call ] && [ "\$2" = log ] && [ "\$3" = read ]; then
	# Harness: emit fixture via real cat (not shimmed) so we do not double-count.
	exec /bin/cat "$fixture"
fi
exit 1
EOF
	chmod +x "${SHIM_DIR}/ubus"
}

tally_total() {
	local tally="$1"
	if [[ ! -s "$tally" ]]; then
		echo 0
		return
	fi
	wc -l <"$tally" | tr -d ' '
}

tally_breakdown() {
	local tally="$1"
	if [[ ! -s "$tally" ]]; then
		echo "  (none)"
		return
	fi
	sort "$tally" | uniq -c | awk '{ printf "  %s: %d\n", $2, $1 }'
}

prepare_shims() {
	local tally="$1"
	local name
	rm -f "${SHIM_DIR:?}"/*
	for name in cat awk dirname jq sed; do
		install_passthrough_shim "$name" "$tally"
	done
	install_ubus_stub "$FIXTURE" "$tally"
	# Prefer real jsonfilter when present; otherwise stub (still counted).
	if env -i PATH="/usr/bin:/bin" command -v jsonfilter >/dev/null 2>&1; then
		install_passthrough_shim jsonfilter "$tally"
	else
		install_jsonfilter_stub "$tally"
	fi
}

run_filter_census() {
	local tally="${WORKDIR}/filter.tally"
	: >"$tally"
	prepare_shims "$tally"
	FWLIVE_CENSUS_TALLY="$tally" PATH="${SHIM_DIR}:${PATH}" \
		sh "$FILTER_SH" <"$FIXTURE" >/dev/null
	printf '%s' "$tally"
}

run_poll_census() {
	local tally="${WORKDIR}/poll.tally"
	: >"$tally"
	prepare_shims "$tally"
	FWLIVE_CENSUS_TALLY="$tally" PATH="${SHIM_DIR}:${PATH}" \
		sh "$RPCD" call poll '{"addresses":["50"]}' >/dev/null
	printf '%s' "$tally"
}

fixture_meta() {
	local bytes entries
	bytes="$(wc -c <"$FIXTURE" | tr -d ' ')"
	if command -v jq >/dev/null 2>&1; then
		entries="$(jq '.log | length' "$FIXTURE")"
	else
		entries="?"
	fi
	printf '%s (%s entries, %s bytes)' "$(basename "$FIXTURE")" "$entries" "$bytes"
}

median_parse_ms() {
	local file="$1"
	local n=50
	local i t
	local -a samples=()
	for ((i = 0; i < n; i++)); do
		t="$({ TIMEFORMAT='%R'; time bash -n "$file" >/dev/null; } 2>&1)"
		samples+=("$t")
	done
	printf '%s\n' "${samples[@]}" | sort -n | awk -v n="$n" '
		{ a[NR] = $1 }
		END {
			if (n % 2) printf "%.1f", a[(n + 1) / 2] * 1000
			else printf "%.1f", (a[n / 2] + a[n / 2 + 1]) / 2 * 1000
		}'
}

echo "=== fork census (#308) ==="
echo "fixture: $(fixture_meta)"
echo "substrate: host/$(uname -m)/$(basename "$(readlink -f /proc/$$/exe 2>/dev/null || echo bash)") (non-authoritative — not BusyBox ash)"
echo "shim cmds: ${SHIM_CMDS[*]}"
echo "accounting: PATH-shim external execs only; builtin-only subshell forks are outside this census"
echo

FILTER_TALLY="$(run_filter_census)"
FILTER_TOTAL="$(tally_total "$FILTER_TALLY")"
echo "--- filter subprocess (production path) ---"
echo "exec total: ${FILTER_TOTAL}"
tally_breakdown "$FILTER_TALLY"
echo "production: dirname (FILTER_DIR) + stdin cat + jsonfilter + heredoc cat + awk"
echo

POLL_TALLY="$(run_poll_census)"
POLL_TOTAL="$(tally_total "$POLL_TALLY")"
echo "--- full poll via rpcd call (host; jshn.sh absent so clamp sed not exercised) ---"
echo "exec total: ${POLL_TOTAL}"
tally_breakdown "$POLL_TALLY"
echo "production: dirname (LIBEXEC_DIR) + ubus + filter chain above"
echo "harness: ubus stub is one counted 'ubus' exec (device: real ubus IPC); fixture emit uses /bin/cat uncounted"
echo "not on host: jshn source+exec, poll_clamp_lines sed (need device / jshn.sh)"
echo

if [[ "$SKIP_PARSE" -eq 0 ]]; then
	echo "--- parse-only medians (bash -n, n=50, ms) ---"
	echo "note: bash -n does not follow '.' sources — measure helpers separately"
	RPCD_MS="$(median_parse_ms "$RPCD")"
	LOGGING_MS="$(median_parse_ms "$LOGGING_SH")"
	FILTER_MS="$(median_parse_ms "$FILTER_SH")"
	CLASSIFY_MS="$(median_parse_ms "$CLASSIFY_SH")"
	# Approximate poll-process parse: entrypoint + sourced logging (host proxy).
	COMBINED_MS="$(awk -v a="$RPCD_MS" -v b="$LOGGING_MS" 'BEGIN { printf "%.1f", a + b }')"
	echo "rpcd:           ${RPCD_MS}  (entrypoint only)"
	echo "logging.sh:     ${LOGGING_MS}  (sourced by rpcd every exec)"
	echo "rpcd+logging:   ${COMBINED_MS}  (sum of medians; host proxy for poll-process parse)"
	echo "filter:         ${FILTER_MS}"
	echo "classify:       ${CLASSIFY_MS}"
	echo
fi

# Machine-readable summary line for CI grepping.
echo "CENSUS_FILTER_TOTAL=${FILTER_TOTAL}"
echo "CENSUS_POLL_TOTAL=${POLL_TOTAL}"

if [[ -n "$EXPECT_FILTER" && "$FILTER_TOTAL" != "$EXPECT_FILTER" ]]; then
	echo "FAIL: filter exec total ${FILTER_TOTAL} != expected ${EXPECT_FILTER}" >&2
	exit 1
fi
if [[ -n "$EXPECT_POLL" && "$POLL_TOTAL" != "$EXPECT_POLL" ]]; then
	echo "FAIL: poll exec total ${POLL_TOTAL} != expected ${EXPECT_POLL}" >&2
	exit 1
fi

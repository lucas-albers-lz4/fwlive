#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Source-contract / static wiring checks for the installed-session ACL smoke
# helper (syntax, ShellCheck, --help, grep pins on helper source). The guest
# HTTP/rpcd ACL run remains manual/lab evidence; this test must not be read
# as proof that rpcd enforced the ACL over HTTP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/qemu-acl-session-smoke.sh"

[[ -x "$SCRIPT" ]] || { echo "ACL session helper is not executable" >&2; exit 1; }
bash -n "$SCRIPT"
shellcheck --severity=warning "$SCRIPT"
"$SCRIPT" --help >/dev/null

grep -Fq 'http://${HOST}:${HTTP_PORT}/ubus' "$SCRIPT" \
	|| { echo "helper must exercise the HTTP ubus endpoint" >&2; exit 1; }
grep -Fq 'luci-app-fwlive' "$SCRIPT" \
	|| { echo "helper must assign the shipped ACL group" >&2; exit 1; }
grep -Fq 'assert_denied' "$SCRIPT" \
	|| { echo "helper must assert the no-grant session" >&2; exit 1; }
for method in logging_status rules poll resolve enable_wan_logging disable_wan_logging; do
	grep -Fq "$method" "$SCRIPT" \
		|| { echo "helper must cover fwlive.$method" >&2; exit 1; }
done
grep -Fq 'call_object "$GRANT_SID" log read' "$SCRIPT" \
	|| { echo "helper must prove the granted session cannot call log.read" >&2; exit 1; }
grep -Fq 'luci-base' "$SCRIPT" \
	|| { echo "helper must grant luci-base on the deny session" >&2; exit 1; }
grep -Fq 'file list' "$SCRIPT" \
	|| { echo "helper must exercise the deny session luci-base grant" >&2; exit 1; }
grep -Fq -- '-32002' "$SCRIPT" \
	|| { echo "helper must pin the JSON-RPC Access denied code" >&2; exit 1; }
grep -Fq 'cleanup_guest' "$SCRIPT" \
	|| { echo "helper must restore the guest rpcd config" >&2; exit 1; }

echo "qemu ACL session helper source-contract checks passed"

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Host-only checks for the logging-uninstall smoke. The guest run remains
# lab evidence; this does not claim a live QEMU/package-payload result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/qemu-logging-uninstall-smoke.sh"
TMP="$(mktemp -d)"

die() { echo "logging-uninstall smoke test FAIL: $*" >&2; exit 1; }

[[ -x "$SCRIPT" ]] || die 'logging-uninstall smoke is not executable'
bash -n "$SCRIPT"
shellcheck --severity=warning "$SCRIPT"

grep -Fq 'apk del luci-app-fwlive' "$SCRIPT" \
	|| die 'smoke must uninstall 25.12 with apk del'
grep -Fq 'opkg remove --force-depends luci-app-fwlive' "$SCRIPT" \
	|| die 'smoke must uninstall 24.10 with opkg remove'
grep -Fq -- '--artifact-only "$SMOKE_ARTIFACT"' "$SCRIPT" \
	|| die 'smoke must reinstall with an explicit package artifact path'
grep -Fq 'OWRT_FWLIVE_ARTIFACT' "$SCRIPT" \
	|| die 'smoke must accept OWRT_FWLIVE_ARTIFACT'
grep -Fq 'FWLIVE_INSTALL_SCRIPT' "$SCRIPT" \
	|| die 'smoke must honor FWLIVE_INSTALL_SCRIPT for host stubs'
grep -Fq -- '--force-reinstall' "$SCRIPT" \
	|| die 'smoke must document same-version APK --force-reinstall'
grep -Fq 'post-upgrade' "$SCRIPT" \
	|| die 'smoke must call out post-upgrade preservation'
grep -Fq 'pre-deinstall' "$SCRIPT" \
	|| die 'smoke must call out pre-deinstall uninstall proof'
grep -Fq 'PKG_UPGRADE=1' "$SCRIPT" \
	|| die 'smoke must record PKG_UPGRADE=1 on the APK upgrade path'
grep -Fq 'two-version' "$SCRIPT" \
	|| die 'smoke must point at the two-version APK upgrade evidence'
grep -Fq 'issue-848-2026-09-27.md' "$SCRIPT" \
	|| die 'smoke must cite the #848 version-changing upgrade evidence'
grep -Fq "ubus call fwlive disable_wan_logging" "$SCRIPT" \
	|| die 'smoke must disable logging before the operator-preservation check'
grep -Fq 'baseline marker remains after successful disable' "$SCRIPT" \
	|| die 'smoke must assert disable retired the baseline marker'
grep -Fq 'disabled_log_value "$PRESERVE_BASE_LOG"' "$SCRIPT" \
	|| die 'smoke must compare the normalized post-disable log mask'
grep -Fq 'log=0' "$SCRIPT" \
	|| die 'smoke must exercise an explicit-zero pre-enable baseline'
grep -Fq "OPERATOR_LOG=2" "$SCRIPT" \
	|| die 'smoke must apply a later operator log-mask change'
grep -Fq 'uninstall overwrote later operator log mask' "$SCRIPT" \
	|| die 'smoke must assert uninstall preserved the operator log mask'

# Same-cell stale artifact must not win when the caller pins OWRT_FWLIVE_ARTIFACT.
# Fixture lives in a temporary tree. The smoke derives out/ from its own
# script directory, so running the repo copy would truncate real SDK packages
# under out/x86_64/24.10.8/fwlive and the EXIT trap would delete them.
TREE="$TMP/tree"
mkdir -p "$TREE/scripts/lib" "$TREE/out/x86_64/24.10.8/fwlive"
cp "$ROOT/scripts/qemu-logging-uninstall-smoke.sh" "$TREE/scripts/"
cp "$ROOT/scripts/qemu-reset-wan-logging.sh" "$TREE/scripts/"
cp "$ROOT/scripts/lib/sdk-matrix.sh" "$TREE/scripts/lib/"
cp "$ROOT/scripts/lib/feeds-lock.sh" "$TREE/scripts/lib/"
chmod 755 "$TREE/scripts/qemu-logging-uninstall-smoke.sh" \
	"$TREE/scripts/qemu-reset-wan-logging.sh"
RUN_SCRIPT="$TREE/scripts/qemu-logging-uninstall-smoke.sh"
CELL="$TREE/out/x86_64/24.10.8/fwlive"
INTENDED="$CELL/luci-app-fwlive_0.1.52-r1_all.ipk"
STALE="$CELL/luci-app-fwlive_0.1.51-r1_all.ipk"
printf 'intended package\n' >"$INTENDED"
printf 'stale same-cell package\n' >"$STALE"
touch -d '@1' "$INTENDED"
touch -d '@2' "$STALE"

# Real build outputs at these names must survive the host test.
REAL_CELL="$ROOT/out/x86_64/24.10.8/fwlive"
REAL_INTENDED="$REAL_CELL/luci-app-fwlive_0.1.52-r1_all.ipk"
REAL_STALE="$REAL_CELL/luci-app-fwlive_0.1.51-r1_all.ipk"
artifact_snapshot() {
	local path="$1"
	if [[ -e "$path" ]]; then
		stat -c '%F %s %Y' "$path"
		sha256sum "$path"
	else
		printf 'absent\n'
	fi
}
REAL_INTENDED_BEFORE="$(artifact_snapshot "$REAL_INTENDED")"
REAL_STALE_BEFORE="$(artifact_snapshot "$REAL_STALE")"
cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin"
cat >"$TMP/bin/qemu-install-fwlive.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$FWLIVE_INSTALL_LOG"
exit 0
EOF
chmod 755 "$TMP/bin/qemu-install-fwlive.sh"

cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -u
cmd="${!#}"
state="${FWLIVE_STUB_STATE:?}"

read_state() {
	[[ -f "$state/$1" ]] && cat "$state/$1" || true
}
write_state() {
	printf '%s' "$2" >"$state/$1"
}

if [[ "$cmd" == 'echo connected' ]]; then
	exit 0
fi
if [[ "$cmd" == 'command -v apk >/dev/null' ]]; then
	exit 0
fi
if [[ "$cmd" == 'command -v ubus >/dev/null && test -x /usr/libexec/rpcd/fwlive' ]]; then
	exit 0
fi
if [[ "$cmd" == 'test -x /usr/libexec/rpcd/fwlive' ]]; then
	exit 0
fi
if [[ "$cmd" == 'uname -m' ]]; then
	printf 'x86_64\n'
	exit 0
fi
if [[ "$cmd" == *'jsonfilter -e'* && "$cmd" == *'wan_zone'* ]]; then
	printf 'wan\n'
	exit 0
fi
if [[ "$cmd" == *'ubus call fwlive logging_status'* ]]; then
	printf '{"wan_zone":"wan","wan_log":false}\n'
	exit 0
fi
if [[ "$cmd" == 'ubus call fwlive enable_wan_logging' ]]; then
	write_state wan_log 1
	write_state baseline 1
	printf '{"ok":true,"changed":true,"wan_zone":"wan"}\n'
	exit 0
fi
if [[ "$cmd" == 'ubus call fwlive disable_wan_logging' ]]; then
	write_state baseline 0
	case "$(read_state wan_log)" in
		0) write_state wan_log '' ;;
		1|2|4) write_state wan_log '' ;;
	esac
	printf '{"ok":true,"changed":true,"wan_zone":"wan"}\n'
	exit 0
fi
if [[ "$cmd" == 'test -f /etc/fwlive/wan-log-baseline' ]]; then
	[[ "$(read_state baseline)" == 1 ]]
	exit $?
fi
if [[ "$cmd" == 'test ! -f /etc/fwlive/wan-log-baseline' ]]; then
	[[ "$(read_state baseline)" != 1 ]]
	exit $?
fi
if [[ "$cmd" == 'apk del luci-app-fwlive' ]]; then
	if [[ "$(read_state phase)" == operator ]]; then
		: # preserve operator mask
	else
		write_state wan_log ''
	fi
	write_state baseline 0
	exit 0
fi
if [[ "$cmd" == *"uci -q get firewall."*".log"* ]]; then
	val="$(read_state wan_log)"
	printf '%s' "$val"
	exit 0
fi
if [[ "$cmd" == *"uci -q set 'firewall.wan.log=0'"* ]]; then
	write_state wan_log 0
	exit 0
fi
if [[ "$cmd" == *"uci -q set 'firewall.wan.log=2'"* ]]; then
	write_state wan_log 2
	write_state phase operator
	exit 0
fi
if [[ "$cmd" == *'uci commit firewall && /etc/init.d/firewall reload'* ]]; then
	exit 0
fi
if [[ "$cmd" == 'rm -f /etc/fwlive/wan-log-baseline' ]]; then
	write_state baseline 0
	exit 0
fi
echo "unexpected ssh command: $cmd" >&2
exit 1
EOF
chmod 755 "$TMP/bin/ssh"

mkdir -p "$TMP/state"
: >"$TMP/install.log"
write_state() { printf '%s' "$2" >"$TMP/state/$1"; }
write_state wan_log ''
write_state baseline 0
write_state phase ''

run_smoke() {
	PATH="$TMP/bin:$PATH" \
	OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 \
	OWRT_FWLIVE_VERSION=24.10.8 \
	OWRT_FWLIVE_ARTIFACT="$INTENDED" \
	FWLIVE_INSTALL_SCRIPT="$TMP/bin/qemu-install-fwlive.sh" \
	FWLIVE_INSTALL_LOG="$TMP/install.log" \
	FWLIVE_STUB_STATE="$TMP/state" \
	bash "$RUN_SCRIPT" >"$TMP/smoke.log" 2>&1
}

run_smoke || die 'host stub smoke run failed (see '"$TMP/smoke.log"')'
grep -Fq 'logging-uninstall smoke passed' "$TMP/smoke.log" \
	|| die 'host stub smoke did not reach success'

install_lines="$(grep -c -- '--artifact-only' "$TMP/install.log" || true)"
[[ "$install_lines" == 3 ]] \
	|| die "expected three artifact-only installs, got ${install_lines}"
intended_count="$(grep -Fc -- "$INTENDED" "$TMP/install.log")"
[[ "$intended_count" == 3 ]] \
	|| die "install helper did not receive the pinned artifact on every reinstall (got ${intended_count})"
grep -Fq -- "$STALE" "$TMP/install.log" \
	&& die 'install helper received the stale same-cell artifact'

if PATH="$TMP/bin:$PATH" OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 \
	OWRT_FWLIVE_VERSION=24.10.8 FWLIVE_STUB_STATE="$TMP/state" \
	bash "$RUN_SCRIPT" >"$TMP/ambiguous.log" 2>&1; then
	die 'smoke accepted ambiguous same-cell artifacts without OWRT_FWLIVE_ARTIFACT'
fi
grep -Fq 'expected exactly one package' "$TMP/ambiguous.log" \
	|| die 'ambiguous artifact fixture did not fail closed'

[[ "$(artifact_snapshot "$REAL_INTENDED")" == "$REAL_INTENDED_BEFORE" ]] \
	|| die 'host test changed the real 0.1.52-r1 SDK artifact'
[[ "$(artifact_snapshot "$REAL_STALE")" == "$REAL_STALE_BEFORE" ]] \
	|| die 'host test changed the real 0.1.51-r1 SDK artifact'
[[ "$INTENDED" == "$TREE/"* && "$STALE" == "$TREE/"* ]] \
	|| die 'fixture packages must stay under the temporary tree'

echo 'qemu logging-uninstall source-contract checks passed'

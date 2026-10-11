#!/usr/bin/env bash
# Verify option-scoped UCI cleanup against the real guest implementation.
#
#   ./scripts/qemu-uci-stage-revert-smoke.sh
#
# Prereqs: QEMU guest up with the current luci-app-fwlive package installed.
set -euo pipefail

HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")

die() { echo "uci-stage-revert smoke FAIL: $*" >&2; exit 1; }

ssh "${SSH_OPTS[@]}" "root@${HOST}" 'sh -s' <<'GUEST'
set -eu
command -v uci >/dev/null 2>&1 || { echo 'uci is unavailable' >&2; exit 1; }
test -r /usr/libexec/fwlive-logging.sh || { echo 'fwlive logging helper is missing' >&2; exit 1; }

UCI_TEST_DIR="$(mktemp -d /tmp/fwlive-uci-stage.XXXXXX)"
trap 'rm -rf "$UCI_TEST_DIR"' EXIT
mkdir -p "$UCI_TEST_DIR/.uci" "$UCI_TEST_DIR/overrides"
# UCI retains /tmp/.uci as an earlier delta search path even with -t. Refuse
# to run if a live firewall delta exists there; every command repeats this
# check so a concurrent operator delta aborts instead of being imported.
if [ -e /tmp/.uci/firewall ] || [ -L /tmp/.uci/firewall ]; then
	echo 'refusing to run with an existing /tmp/.uci/firewall delta' >&2
	exit 1
fi
cat >"$UCI_TEST_DIR/firewall" <<'EOF'
config zone 'wan'
	option name 'wan'
	list log '2'
EOF
REAL_UCI="$(command -v uci)"
uci() {
	if [ -e /tmp/.uci/firewall ] || [ -L /tmp/.uci/firewall ]; then
		echo 'refusing to run after a live /tmp/.uci/firewall delta appeared' >&2
		return 1
	fi
	"$REAL_UCI" -c "$UCI_TEST_DIR" -C "$UCI_TEST_DIR/overrides" \
		-t "$UCI_TEST_DIR/.uci" "$@"
}
# shellcheck disable=SC1091
. /usr/libexec/fwlive-logging.sh

# A foreign option staged after fwlive's write must survive while the exact
# fwlive log delta is removed (setting the committed value again is not enough).
uci set firewall.wan.log=3
uci set firewall.wan.description='foreign'
staged="$(uci -q changes firewall)"
wan_log_revert_staged_option_if_ours wan 3 "$staged" \
	|| { echo 'failed to revert the uniquely owned log delta' >&2; exit 1; }
after="$(uci -q changes firewall)"
printf '%s\n' "$after" | grep -Fq "firewall.wan.description='foreign'" \
	|| { echo 'option-scoped revert discarded the foreign delta' >&2; exit 1; }
printf '%s\n' "$after" | grep -Fq 'firewall.wan.log=' \
	&& { echo 'option-scoped revert left the fwlive log delta staged' >&2; exit 1; }
[ "$(uci -q get firewall.wan.log)" = 2 ] \
	|| { echo 'option-scoped revert changed the committed log value' >&2; exit 1; }

# The disable/rollback path deletes log when clearing the last filter-log bit.
# Revert that staged deletion without losing a concurrent unrelated option.
uci -q revert firewall
uci set firewall.wan.log=1
uci commit firewall
uci delete firewall.wan.log
uci set firewall.wan.description='foreign-delete'
staged="$(uci -q changes firewall)"
wan_log_revert_staged_option_if_ours wan '' "$staged" \
	|| { echo 'failed to revert the uniquely owned log deletion' >&2; exit 1; }
after="$(uci -q changes firewall)"
printf '%s\n' "$after" | grep -Fq "firewall.wan.description='foreign-delete'" \
	|| { echo 'delete cleanup discarded the foreign delta' >&2; exit 1; }
printf '%s\n' "$after" | grep -Fq 'firewall.wan.log=' \
	&& { echo 'delete cleanup left the fwlive log deletion staged' >&2; exit 1; }
[ "$(uci -q get firewall.wan.log)" = 1 ] \
	|| { echo 'option-scoped delete revert changed the committed log value' >&2; exit 1; }

# List deltas use += / -= in `uci changes` and touch the same option; cleanup
# must not treat a scalar set as uniquely owned when either list edit exists.
uci -q revert firewall
cat >"$UCI_TEST_DIR/firewall" <<'EOF'
config zone 'wan'
	option name 'wan'
	list log '2'
EOF
uci add_list firewall.wan.log=3
uci del_list firewall.wan.log=2
staged="$(uci -q changes firewall)"
if wan_log_revert_staged_option_if_ours wan 3 "$staged"; then
	echo 'same-option add_list/del_list staging was reverted' >&2
	exit 1
fi
printf '%s\n' "$staged" | grep -Fq "firewall.wan.log+='3'" \
	|| { echo 'UCI did not report the same-option list addition' >&2; exit 1; }
printf '%s\n' "$staged" | grep -Fq "firewall.wan.log-='2'" \
	|| { echo 'UCI did not report the same-option list deletion' >&2; exit 1; }
printf '%s\n' "$(uci -q changes firewall)" | grep -Fq "firewall.wan.log+='3'" \
	|| { echo 'same-option list addition was discarded' >&2; exit 1; }
printf '%s\n' "$(uci -q changes firewall)" | grep -Fq "firewall.wan.log-='2'" \
	|| { echo 'same-option list deletion was discarded' >&2; exit 1; }

# A distinct same-option writer is not attributable to fwlive. Preserve its
# staged final value rather than reverting the option wholesale.
uci -q revert firewall
uci set firewall.wan.log=3
uci set firewall.wan.log=9
uci set firewall.wan.description='foreign-again'
staged="$(uci -q changes firewall)"
if wan_log_revert_staged_option_if_ours wan 3 "$staged"; then
	echo 'ambiguous same-option staging was reverted' >&2
	exit 1
fi
[ "$(uci -q get firewall.wan.log)" = 9 ] \
	|| { echo 'ambiguous same-option staged value was not preserved' >&2; exit 1; }
printf '%s\n' "$staged" | grep -Fq "firewall.wan.log='9'" \
	|| { echo 'real UCI did not expose the competing same-option value' >&2; exit 1; }

echo 'option-scoped UCI staging/revert passed'
GUEST

echo 'qemu UCI stage/revert integration smoke passed'

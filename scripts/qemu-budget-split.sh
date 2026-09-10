#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Measure the fwlive poll budget on a running OpenWrt armsr guest (#310).
#
# The guest clock is /proc/uptime (centiseconds). Every stage emits five raw
# samples; stages below clock resolution are run in a batch and retain the
# batch size. Fixture and real-logd runs stay separate.
#
# Usage:
#   OPENWRT_SSH_PORT=2223 ./scripts/qemu-budget-split.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
FIXTURE="${1:-${ROOT}/tests/fixtures/logread-2000.json}"
REMOTE_FIXTURE=/tmp/fwlive-logread-2000.json
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")

[[ -f "$FIXTURE" ]] || { echo "fixture not found: $FIXTURE" >&2; exit 1; }
ssh "${SSH_OPTS[@]}" "root@$HOST" 'echo connected' >/dev/null

echo "Copying $(basename "$FIXTURE") to root@$HOST:$PORT:$REMOTE_FIXTURE" >&2
if scp -O -q -P "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	"$FIXTURE" "root@$HOST:$REMOTE_FIXTURE" 2>/dev/null; then
	:
else
	ssh "${SSH_OPTS[@]}" "root@$HOST" "cat > $REMOTE_FIXTURE" <"$FIXTURE"
fi

ssh "${SSH_OPTS[@]}" "root@$HOST" sh -s -- "$REMOTE_FIXTURE" <<'REMOTE'
set -eu
fixture=$1

clock_cs() {
	read uptime _ </proc/uptime
	seconds=${uptime%.*}
	fraction=${uptime#*.}
	fraction=${fraction#0}
	[ -n "$fraction" ] || fraction=0
	printf '%s\n' $((seconds * 100 + fraction))
}

measure() {
	name=$1
	repeats=$2
	shift 2
	i=1
	while [ "$i" -le 5 ]; do
		start=$(clock_cs)
		j=1
		while [ "$j" -le "$repeats" ]; do
			"$@" </dev/null >/dev/null 2>&1 || true
			j=$((j + 1))
		done
		end=$(clock_cs)
		elapsed=$((end - start))
		printf 'PROFILE_SAMPLE stage=%s repeats=%s elapsed_cs=%s per_call_ms=%s\n' \
			"$name" "$repeats" "$elapsed" "$((elapsed * 10 / repeats))"
		i=$((i + 1))
	done
}

stage_rpcd_parse() { sh -n /usr/libexec/rpcd/fwlive; }
stage_filter_parse() { sh -n /usr/libexec/fwlive-log-filter.sh; }
stage_jshn() { jshn -r '{"addresses":["50"]}'; }
stage_log_capture() { ubus call log read '{"lines":2000,"stream":false,"oneshot":true}'; }
stage_filter_cat() { cat "$fixture"; }
stage_jsonfilter() { jsonfilter -e '@.log[*]' "$fixture"; }
stage_heredoc_cat() {
	cat <<'EOF'
classifier-input
EOF
}
stage_awk_classify() {
	(
		set +u
		. /usr/libexec/fwlive-is-firewall-event.sh
		_fwlive_run_classify json </tmp/fwlive-logread-2000.json
	)
}
stage_filter_fixture() { /usr/libexec/fwlive-log-filter.sh <"$fixture"; }
stage_poll_real() { ubus call fwlive poll '{"addresses":["50"]}'; }

echo "PROFILE_META release=$(sed -n 's/^DISTRIB_RELEASE=//p' /etc/openwrt_release)"
echo "PROFILE_META revision=$(sed -n 's/^DISTRIB_REVISION=//p' /etc/openwrt_release)"
echo "PROFILE_META arch=$(uname -m) busybox=$(opkg status busybox 2>/dev/null | sed -n 's/^Version: //p')"
echo "PROFILE_META clock=/proc/uptime resolution_centiseconds"
echo "PROFILE_META fixture=$(wc -c <"$fixture" | tr -d ' ')_bytes"

# Batches make elapsed values meaningful when a single command is below 10 ms.
measure rpcd_parse 20 stage_rpcd_parse
measure jshn 20 stage_jshn
measure log_read_capture 5 stage_log_capture
measure filter_parse 20 stage_filter_parse
measure filter_stdin_cat 10 stage_filter_cat
measure jsonfilter 5 stage_jsonfilter
measure heredoc_cat 50 stage_heredoc_cat
measure awk_classify 5 stage_awk_classify
measure filter_fixture 1 stage_filter_fixture
measure poll_real 1 stage_poll_real

# Count PATH-observable commands for one production-shaped fixture poll.
shim_dir=/tmp/fwlive-budget-shims
tally=/tmp/fwlive-budget-tally
rm -rf "$shim_dir"
mkdir "$shim_dir"
cat >"$shim_dir/wrap" <<'WRAP'
#!/bin/sh
name=${0##*/}
printf '%s\n' "$name" >>/tmp/fwlive-budget-tally
case "$name" in
  cat) real=/bin/cat ;;
  jsonfilter) real=/usr/bin/jsonfilter ;;
  awk) real=/usr/bin/awk ;;
  dirname) real=/usr/bin/dirname ;;
  sed) real=/bin/sed ;;
  jshn) real=/usr/bin/jshn ;;
  ubus)
    if [ "$1" = call ] && [ "$2" = log ] && [ "$3" = read ]; then
      exec /bin/cat /tmp/fwlive-logread-2000.json
    fi
    real=/bin/ubus ;;
  *) exit 127 ;;
esac
exec "$real" "$@"
WRAP
chmod +x "$shim_dir/wrap"
for command in cat jsonfilter awk dirname sed jshn ubus; do
	ln -s wrap "$shim_dir/$command"
done
: >"$tally"
printf '%s' '{"addresses":["50"]}' \
	| PATH="$shim_dir:$PATH" /usr/libexec/rpcd/fwlive call poll >/dev/null 2>&1 || true
sort "$tally" | uniq -c | awk '{ printf "PROFILE_EXEC command=%s count=%s\n", $2, $1 }'
REMOTE

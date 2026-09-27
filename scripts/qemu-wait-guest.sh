#!/usr/bin/env bash
# Wait until a QEMU OpenWrt guest answers SSH (hostfwd) and optionally run a command.
# Generic waiter for x86 and armsr. Contract: OPENWRT_HOST, OPENWRT_SSH_PORT,
# OPENWRT_USER, MAX_WAIT, INTERVAL, optional --cmd.
#
# Usage:
#   ./scripts/qemu-wait-guest.sh
#   ./scripts/qemu-wait-guest.sh --cmd 'uname -r'
#   OPENWRT_SSH_PORT=2222 MAX_WAIT=600 ./scripts/qemu-wait-guest.sh
# MAX_WAIT bounds readiness; --cmd runs once after the read-only probe succeeds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/qemu-lab-net.sh
source "${ROOT}/scripts/lib/qemu-lab-net.sh"

HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
USER="${OPENWRT_USER:-root}"
MAX_WAIT="${MAX_WAIT:-600}"
INTERVAL="${INTERVAL:-15}"
CMD=""
qemu_lab_validate_port OPENWRT_SSH_PORT "$PORT" || exit 1
qemu_lab_validate_int MAX_WAIT "$MAX_WAIT" 1 7200 || exit 1
qemu_lab_validate_int INTERVAL "$INTERVAL" 1 120 || exit 1
SSH_OPTS=(
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o BatchMode=yes
	-o NumberOfPasswordPrompts=0
)

while [[ $# -gt 0 ]]; do
	case "$1" in
		--cmd)
			CMD="${2:?usage: qemu-wait-guest.sh --cmd CMD}"
			shift 2
			;;
		-h | --help)
			sed -n '1,13p' "$0"
			exit 0
			;;
		*)
			echo "unknown arg: $1" >&2
			exit 1
			;;
	esac
done

# Quote the caller's command as one POSIX sh -c argument on the guest.
quote_sh_arg() {
	local value="$1" quote="'" result="'" prefix
	while [[ "$value" == *"$quote"* ]]; do
		prefix=${value%%"$quote"*}
		result+="${prefix}'\\''"
		value=${value#*"$quote"}
	done
	result+="${value}'"
	printf '%s' "$result"
}

deadline=$((SECONDS + MAX_WAIT))
attempt=0

while [[ $SECONDS -lt $deadline ]]; do
	remaining=$((deadline - SECONDS))
	if (( remaining <= 0 )); then
		break
	fi
	if (( remaining > 20 )); then
		connect_timeout=20
	else
		connect_timeout=$remaining
	fi
	attempt=$((attempt + 1))
	if probe_out="$(ssh -p "$PORT" "${SSH_OPTS[@]}" -o "ConnectTimeout=$connect_timeout" "${USER}@${HOST}" 'echo READY' 2>&1)"; then
		echo "guest ready after ~${attempt} attempts (${SECONDS}s)"
		if [[ -z "$CMD" ]]; then
			[[ -n "$probe_out" ]] && printf '%s\n' "$probe_out"
			exit 0
		fi

		status_marker="__FWLIVE_REMOTE_STATUS_$$_${RANDOM}__"
		remote_command="sh -c $(quote_sh_arg "$CMD"); _fwlive_status=\$?; printf '\\n${status_marker}%s\\n' \"\$_fwlive_status\""
		if command_out="$(ssh -p "$PORT" "${SSH_OPTS[@]}" -o "ConnectTimeout=$connect_timeout" "${USER}@${HOST}" "$remote_command" 2>&1)"; then
			if [[ "$command_out" == *"$status_marker"* ]]; then
				remote_status=${command_out##*"$status_marker"}
			else
				remote_status=''
			fi
			if [[ "$remote_status" =~ ^[0-9]{1,3}$ ]]; then
				command_out=${command_out%$'\n'"$status_marker$remote_status"}
				[[ -n "$command_out" ]] && printf '%s\n' "$command_out"
				if (( 10#$remote_status == 0 )); then
					exit 0
				fi
				echo "error: remote command exited with status $remote_status" >&2
				exit "$remote_status"
			fi
			echo "error: remote command returned without its status marker; it may have run" >&2
			[[ -n "$command_out" ]] && printf '%s\n' "$command_out" >&2
			exit 1
		else
			ssh_status=$?
			echo "error: SSH transport failed while running --cmd (ssh exit $ssh_status; command may have run and was not retried)" >&2
			[[ -n "$command_out" ]] && printf '%s\n' "$command_out" >&2
			exit 1
		fi
	else
		ssh_status=$?
		echo "attempt ${attempt}: SSH probe failed (ssh exit $ssh_status): ${probe_out:-ssh failed}"
	fi
	remaining=$((deadline - SECONDS))
	if (( remaining > 0 )); then
		sleep_for=$INTERVAL
		if (( sleep_for > remaining )); then
			sleep_for=$remaining
		fi
		sleep "$sleep_for"
	fi
done

echo "error: SSH readiness probe did not succeed for ${HOST}:${PORT} within ${MAX_WAIT}s" >&2
echo "hint: stop other QEMU, then ./scripts/run-openwrt-x86-qemu.sh or ./scripts/run-openwrt-armsr-armv8-qemu.sh" >&2
exit 1

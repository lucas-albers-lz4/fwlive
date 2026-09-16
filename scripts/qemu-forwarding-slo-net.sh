#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Create and inspect the two-endpoint host topology used by the forwarding-SLO
# measurement. This command does not start QEMU or claim a forwarding result.
#
# Usage:
#   sudo ./scripts/qemu-forwarding-slo-net.sh setup
#   ./scripts/qemu-forwarding-slo-net.sh qemu-args
#   sudo ./scripts/qemu-forwarding-slo-net.sh status
#   sudo ./scripts/qemu-forwarding-slo-net.sh teardown
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/qemu-forwarding-slo-net.sh
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/qemu-forwarding-slo-net.sh"

usage() {
	sed -n '5,14p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	setup)
		# Setup is transactional: a failed namespace/link operation must not
		# leave a partial owned topology behind for a later run.
		trap 'fwlive_slo_net_teardown || true' ERR
		fwlive_slo_net_setup "${2:-${SUDO_USER:-${USER:-}}}"
		trap - ERR
		;;
	qemu-args)
		fwlive_slo_net_qemu_args
		;;
	status)
		fwlive_slo_net_require_tools
		fwlive_slo_net_validate_names
		fwlive_slo_net_status
		;;
	teardown)
		fwlive_slo_net_teardown
		;;
	-h|--help|"")
		usage 0
		;;
	*)
		echo "unknown command: $1" >&2
		usage >&2
		exit 1
		;;
esac

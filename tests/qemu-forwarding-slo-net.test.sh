#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Static/unit checks for the host-side forwarding-SLO topology helper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/qemu-forwarding-slo-net.sh
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/qemu-forwarding-slo-net.sh"

die() { echo "qemu-forwarding-slo-net test FAIL: $*" >&2; exit 1; }
ok() { echo "qemu-forwarding-slo-net test OK: $*"; }

for name in \
	"$FWLIVE_SLO_LAN_NETNS" "$FWLIVE_SLO_WAN_NETNS" \
	"$FWLIVE_SLO_LAN_BRIDGE" "$FWLIVE_SLO_WAN_BRIDGE" \
	"$FWLIVE_SLO_LAN_TAP" "$FWLIVE_SLO_WAN_TAP" \
	"$FWLIVE_SLO_LAN_VETH" "$FWLIVE_SLO_WAN_VETH" \
	"$FWLIVE_SLO_LAN_PEER" "$FWLIVE_SLO_WAN_PEER"; do
	[[ "$name" == "${FWLIVE_SLO_PREFIX}"* ]] || die "resource outside owned prefix: $name"
	[[ ${#name} -le 15 ]] || die "resource exceeds Linux IFNAMSIZ: $name"
done
fwlive_slo_net_validate_names
ok "default resource names are prefixed and Linux-safe"

if FWLIVE_SLO_LAN_NETNS="$FWLIVE_SLO_PREFIX" bash -c \
	'source "$1"; fwlive_slo_net_validate_names' bash \
	"${ROOT}/scripts/lib/qemu-forwarding-slo-net.sh" 2>/dev/null; then
	die "bare owned prefix must be rejected as a resource name"
fi
ok "bare owned prefix is rejected"

if FWLIVE_SLO_LAN_NETNS="${FWLIVE_SLO_PREFIX}valid/bad" bash -c \
	'source "$1"; fwlive_slo_net_validate_names' bash \
	"${ROOT}/scripts/lib/qemu-forwarding-slo-net.sh" 2>/dev/null; then
	die "resource suffix must reject characters outside the allowlist"
fi
ok "resource suffix is fully restricted"

if FWLIVE_SLO_WAN_TAP="$FWLIVE_SLO_LAN_TAP" bash -c \
	'source "$1"; fwlive_slo_net_validate_names' bash \
	"${ROOT}/scripts/lib/qemu-forwarding-slo-net.sh" 2>/dev/null; then
	die "duplicate resource names must be rejected"
fi
ok "duplicate resource names are rejected before setup"

args="$(fwlive_slo_net_qemu_args)"
grep -Fq "ifname=${FWLIVE_SLO_LAN_TAP}" <<<"$args" || die "LAN TAP missing from QEMU args"
grep -Fq "ifname=${FWLIVE_SLO_WAN_TAP}" <<<"$args" || die "WAN TAP missing from QEMU args"
grep -Fq 'script=no,downscript=no' <<<"$args" || die "QEMU TAP scripts must be disabled"
[[ "$(grep -Fc 'netdev tap' <<<"$args")" -eq 2 ]] || die "expected two TAP netdevs"
ok "QEMU args expose two explicit TAP links"

custom_args="$(FWLIVE_SLO_LAN_MAC=02:00:00:00:00:01 FWLIVE_SLO_WAN_MAC=02:00:00:00:00:02 \
	bash -c 'source "$1"; fwlive_slo_net_qemu_args' bash \
	"${ROOT}/scripts/lib/qemu-forwarding-slo-net.sh")"
grep -Fq 'mac=02:00:00:00:00:01' <<<"$custom_args" || die "LAN MAC override missing from QEMU args"
grep -Fq 'mac=02:00:00:00:00:02' <<<"$custom_args" || die "WAN MAC override missing from QEMU args"
ok "QEMU args honor guest MAC overrides"

FWLIVE_SLO_QEMU_NET_MODEL=unsupported bash -c \
	'source "$1"' bash "${ROOT}/scripts/lib/qemu-forwarding-slo-net.sh" 2>/dev/null ||
	die "unsupported QEMU NIC model must not fail library loading"
if FWLIVE_SLO_QEMU_NET_MODEL=unsupported bash -c \
	'source "$1"; fwlive_slo_net_qemu_args' bash "${ROOT}/scripts/lib/qemu-forwarding-slo-net.sh" 2>/dev/null; then
	die "unsupported QEMU NIC model must be rejected when emitting QEMU args"
fi
model_args="$(FWLIVE_SLO_QEMU_NET_MODEL=e1000 bash -c \
	'source "$1"; fwlive_slo_net_qemu_args' bash \
	"${ROOT}/scripts/lib/qemu-forwarding-slo-net.sh")"
grep -Fq -- '-device e1000,' <<<"$model_args" || die "QEMU NIC model override missing"
ok "QEMU NIC model is validated and configurable"

echo "qemu-forwarding-slo-net tests passed"

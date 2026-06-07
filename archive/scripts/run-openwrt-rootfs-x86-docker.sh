#!/usr/bin/env bash
# Deprecated wrapper — use ./scripts/run-openwrt-x86-experiment.sh
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/run-openwrt-x86-experiment.sh" "$@"

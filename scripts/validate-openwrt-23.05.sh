#!/usr/bin/env bash
# Back-compat wrapper — prefer: ./scripts/validate-openwrt.sh --version 23.05
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validate-openwrt.sh" --version 23.05 "$@"

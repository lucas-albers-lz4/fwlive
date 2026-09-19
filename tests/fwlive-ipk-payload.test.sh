#!/usr/bin/env bash
# Compatibility entry point; the payload inspector now covers both ipk and apk.
set -euo pipefail

exec "$(dirname "$0")/fwlive-package-payload.test.sh" "$@"

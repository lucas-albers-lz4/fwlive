#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}/lab"

podman compose -f compose.yml up -d
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

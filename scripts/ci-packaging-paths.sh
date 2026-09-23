#!/usr/bin/env bash
# CI entry: print run_matrix=true|false for test-ipk-payload step gating (#557).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/packaging-ci-paths.sh
source "$ROOT/scripts/lib/packaging-ci-paths.sh"

packaging_ci_decide

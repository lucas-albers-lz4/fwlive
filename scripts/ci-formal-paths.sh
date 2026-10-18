#!/usr/bin/env bash
# CI entry: emit run_formal=true|false for the always-reporting formal-tlc job.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/formal-ci-paths.sh
source "$ROOT/scripts/lib/formal-ci-paths.sh"

formal_ci_decide

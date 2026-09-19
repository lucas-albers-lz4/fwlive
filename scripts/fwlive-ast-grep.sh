#!/usr/bin/env bash
# Invariant rules for the shipped LuCI surface (docs/developer/security-model.md).
#
# The rule set lives in scripts/ast-grep-rules/ and is shared with CodeRabbit
# (reviews.tools.ast-grep.rule_dirs in .coderabbit.yaml), so a violation shows up
# both here and in review. Pinned to the CLI version CodeRabbit runs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED="0.45.3"

if ! command -v ast-grep >/dev/null 2>&1; then
	echo "Install ast-grep to run this gate: pipx install 'ast-grep-cli==${EXPECTED}'" >&2
	exit 1
fi

ver="$(ast-grep --version | head -n1 | awk '{print $2}')"
if [[ "$ver" != "$EXPECTED" ]]; then
	echo "expected ast-grep '${EXPECTED}', got '${ver}'" >&2
	exit 1
fi

cd "$ROOT"
ast-grep scan --config sgconfig.yml .

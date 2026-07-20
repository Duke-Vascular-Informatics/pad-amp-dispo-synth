#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push

echo "Git hooks installed for this repository."
echo "  hooks path: .githooks"
echo ""
echo "To bypass hooks for one command:"
echo "  SKIP_ANALYST_HOOKS=1 git commit -m 'message'"

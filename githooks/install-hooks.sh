#!/usr/bin/env bash
# Install git hooks for the dotfiles repository
#
# Usage:
#   ./githooks/install-hooks.sh
#
# To uninstall:
#   git config --unset core.hooksPath

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null || echo .git)"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}Installing git hooks...${NC}"

# Set git hooks path for this repository
git config core.hooksPath "$HOOKS_DIR"

echo -e "${GREEN}✅ Git hooks installed!${NC}"
echo
echo "Hooks installed:"
for hook in "$HOOKS_DIR"/*; do
    if [[ -f "$hook" ]] && [[ -x "$hook" ]] && [[ "$(basename "$hook")" != "install-hooks.sh" ]]; then
        echo "  • $(basename "$hook")"
    fi
done

echo
echo -e "${BLUE}To test the pre-commit hook:${NC}"
echo "  1. Create a test file with a secret:"
echo "     echo 'password=\"secret123\"' > test-secret.sh"
echo "  2. Try to commit it:"
echo "     git add test-secret.sh && git commit -m \"test\""
echo "  3. The commit should be blocked"
echo
echo -e "${BLUE}To uninstall hooks:${NC}"
echo "  git config --unset core.hooksPath"
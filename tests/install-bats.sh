#!/usr/bin/env bash
# Install bats-core and helpers for testing

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}Installing bats testing framework...${NC}"

# Install via Homebrew (macOS)
if [[ "$OSTYPE" == "darwin"* ]]; then
    if command -v brew &>/dev/null; then
        echo "Installing bats-core via Homebrew..."
        brew install bats-core
        
        # Install helpful bats libraries
        brew tap kaos/shell
        brew install bats-assert
        brew install bats-support
        brew install bats-file
    else
        echo -e "${YELLOW}Homebrew not found. Install manually:${NC}"
        echo "  git clone https://github.com/bats-core/bats-core.git"
        echo "  cd bats-core"
        echo "  ./install.sh /usr/local"
    fi
else
    # Linux installation
    echo "Installing bats-core from source..."
    git clone https://github.com/bats-core/bats-core.git /tmp/bats-core
    cd /tmp/bats-core
    sudo ./install.sh /usr/local
fi

echo -e "${GREEN}✅ Bats installation complete!${NC}"
echo
echo "Run tests with:"
echo "  ./tests/run-tests.sh"
#!/usr/bin/env bash
# Run all dotfiles tests

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Get script directory
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS_DIR"

# Check if bats is installed
if ! command -v bats &>/dev/null; then
    echo -e "${YELLOW}⚠️  Bats is not installed${NC}"
    echo
    echo "Install with:"
    echo "  brew install bats-core  # macOS"
    echo "  # or"
    echo "  ./tests/install-bats.sh"
    exit 1
fi

# Parse arguments
VERBOSE=false
SPECIFIC_TEST=""
WATCH=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -w|--watch)
            WATCH=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [test-file]"
            echo
            echo "Options:"
            echo "  -v, --verbose    Show verbose output"
            echo "  -w, --watch      Watch for changes and re-run tests"
            echo "  -h, --help       Show this help message"
            echo
            echo "Examples:"
            echo "  $0                    # Run all tests"
            echo "  $0 dots.bats          # Run specific test file"
            echo "  $0 -v                 # Run with verbose output"
            echo "  $0 -w                 # Watch mode"
            exit 0
            ;;
        *)
            SPECIFIC_TEST="$1"
            shift
            ;;
    esac
done

# Function to run tests
run_tests() {
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        Dotfiles Test Suite             ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo
    
    local test_files
    if [[ -n "$SPECIFIC_TEST" ]]; then
        test_files="$SPECIFIC_TEST"
    else
        # Run simpler tests that don't require complex setup
        test_files="dots-simple.bats git-hooks.bats sync.bats"
    fi
    
    # Count total tests
    local total_tests=0
    for file in $test_files; do
        if [[ -f "$file" ]]; then
            local count=$(grep -c "^@test" "$file" || true)
            total_tests=$((total_tests + count))
        fi
    done
    
    echo -e "${BLUE}Running $total_tests tests...${NC}"
    echo
    
    # Run tests
    local bats_args=""
    if [[ "$VERBOSE" == true ]]; then
        bats_args="-v"
    fi
    
    if bats $bats_args $test_files; then
        echo
        echo -e "${GREEN}═══ All tests passed! ═══${NC}"
        return 0
    else
        echo
        echo -e "${RED}═══ Some tests failed ═══${NC}"
        return 1
    fi
}

# Watch mode
if [[ "$WATCH" == true ]]; then
    echo -e "${YELLOW}Watch mode: Tests will re-run on file changes${NC}"
    echo -e "${YELLOW}Press Ctrl+C to exit${NC}"
    echo
    
    # Initial run
    run_tests || true
    
    # Watch for changes
    if command -v fswatch &>/dev/null; then
        fswatch -o . ../**/*.sh ../**/*.bash | while read; do
            clear
            run_tests || true
        done
    else
        echo -e "${YELLOW}fswatch not found. Install with: brew install fswatch${NC}"
        echo "Falling back to simple loop..."
        while true; do
            sleep 2
            clear
            run_tests || true
        done
    fi
else
    # Single run
    run_tests
fi
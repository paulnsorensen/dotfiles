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
TESTS_DIR="$(cd "${0%/*}" && pwd)"
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
SPECIFIC_TESTS=()
WATCH=false
SHARD_SPEC=""
TIMINGS_DIR=""

while (($#)); do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -w|--watch)
            WATCH=true
            shift
            ;;
        --shard)
            SHARD_SPEC="$2"
            shift 2
            ;;
        --timings)
            TIMINGS_DIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [test-file ...]"
            echo
            echo "Options:"
            echo "  -v, --verbose    Show full test output (default: failures only)"
            echo "  -w, --watch      Watch for changes and re-run tests"
            echo "  --shard I/N      Run only shard I of N (default file glob only;"
            echo "                   ignored when test files are given explicitly)"
            echo "  --timings DIR    Write a per-file JUnit timing report to DIR"
            echo "                   (source data for tests/shard-weights.tsv)"
            echo "  -h, --help       Show this help message"
            echo
            echo "Examples:"
            echo "  $0                            # Run all tests"
            echo "  $0 dots.bats                  # Run a single test file"
            echo "  $0 a.bats b.bats              # Run multiple test files"
            echo "  $0 -v                         # Run with verbose output"
            echo "  $0 -w                         # Watch mode"
            echo "  $0 --shard 1/4                # Run shard 1 of 4"
            exit 0
            ;;
        *)
            SPECIFIC_TESTS+=("$1")
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
    if (( ${#SPECIFIC_TESTS[@]} > 0 )); then
        test_files="${SPECIFIC_TESTS[*]}"
    else
        # Glob every .bats file in this dir so new tests pick up automatically.
        local _f _found=()
        for _f in *.bats; do
            [[ -f "$_f" ]] && _found+=("$_f")
        done
        if (( ${#_found[@]} == 0 )); then
            echo -e "${RED}✘ No *.bats files found in $TESTS_DIR${NC}" >&2
            echo "  (Did the working directory get clobbered, or is this a vendored copy?)" >&2
            return 1
        fi

        if [[ -n "$SHARD_SPEC" ]]; then
            local shard_index="${SHARD_SPEC%%/*}" shard_total="${SHARD_SPEC##*/}"
            # shellcheck source=lib/shard.sh
            source "$TESTS_DIR/lib/shard.sh"
            local -a _shard_found=()
            while IFS= read -r _f; do
                _shard_found+=("$_f")
            done < <(shard_files "$shard_index" "$shard_total" "$TESTS_DIR/shard-weights.tsv" "${_found[@]}")
            _found=("${_shard_found[@]}")
        fi

        test_files="${_found[*]}"
    fi

    # Count total tests
    local total_tests=0
    for file in $test_files; do
        if [[ -f "$file" ]]; then
            local count
            count=$(grep -c "^@test" "$file" || true)
            ((total_tests += count))
        fi
    done

    echo -e "${BLUE}Running $total_tests tests...${NC}"
    echo

    # Suppress GNU parallel's citation notice (bats --jobs dispatches via parallel)
    mkdir -p "$HOME/.parallel" && touch "$HOME/.parallel/will-cite"

    # Core count, portably: nproc on Linux, sysctl on macOS (which has no nproc
    # unless coreutils is installed). Probing sysctl FIRST silently fell back to
    # 4 on every Linux box — `sysctl -n hw.ncpu` is a macOS key, so a 24-core
    # machine ran the suite 6x under-parallelised.
    local jobs
    jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

    # Parallel across files AND within files. A file whose tests share state
    # opts out via BATS_NO_PARALLELIZE_WITHIN_FILE=true in its setup_file().
    local -a timing_args=()
    if [[ -n "$TIMINGS_DIR" ]]; then
        # bats -o/--output requires the directory to already exist.
        mkdir -p "$TIMINGS_DIR"
        timing_args=(--report-formatter junit --output "$TIMINGS_DIR")
    fi

    local rc=0
    # shellcheck disable=SC2086 # intentional word splitting for multiple file args
    if [[ "$VERBOSE" == true ]]; then
        bats --jobs "$jobs" "${timing_args[@]}" $test_files || rc=$?
    else
        # TAP output filtered to failures only (plan line + not-ok + diagnostics)
        bats --formatter tap --jobs "$jobs" "${timing_args[@]}" $test_files |
            grep -v '^ok ' || rc=$?
    fi

    if (( rc == 0 )); then
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
        fswatch -o . ../**/*.sh ../**/*.bash | while read -r; do
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

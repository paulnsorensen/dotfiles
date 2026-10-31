# shellcheck shell=bash
# term-colors.sh — ANSI colour constants for the bin/ scripts.
#
# Constants only — no top-level side effects, so sourcing is safe from bats
# tests. Use them with `echo -e`. NC and RESET are the same reset code.
# shellcheck disable=SC2034  # consumers use these variables

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'
RESET='\033[0m'

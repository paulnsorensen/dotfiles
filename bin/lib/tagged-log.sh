# shellcheck shell=bash
# tagged-log.sh — log/ok/warn/err helpers that prefix each line with [LOG_TAG].
#
# Set LOG_TAG before you call a helper. log and ok write to stdout.
# warn and err write to stderr. Sourcing sets no shell options.

_tagged_log_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/term-colors.sh
source "${_tagged_log_dir}/term-colors.sh" || return 1
unset _tagged_log_dir

log()  { echo -e "${BLUE}[${LOG_TAG}]${NC} $*"; }
ok()   { echo -e "${GREEN}[${LOG_TAG}]${NC} $*"; }
warn() { echo -e "${YELLOW}[${LOG_TAG}]${NC} $*" >&2; }
err()  { echo -e "${RED}[${LOG_TAG}]${NC} $*" >&2; }

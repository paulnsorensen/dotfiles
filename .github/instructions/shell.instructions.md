---
applyTo: "**/*.{sh,zsh,bash}"
---

- Use `set -euo pipefail` at the top of executable scripts
- `.zsh` files in `zsh/` are sourced, not executed — do not add shebangs
- Quote all variable expansions: `"$var"`, not `$var`
- Use `[[ ]]` over `[ ]` for conditionals
- Use `local` for all function-scoped variables
- Prefer `printf` over `echo` for portable output
- Use functions for any logic that repeats or exceeds 10 lines
- Claude/MCP aliases go in `zsh/claude.zsh`, general utilities in `zsh/aliases.zsh`
- Test shell changes with `dots test` (bats)

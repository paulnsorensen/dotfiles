# Python — pyproject.toml with uv Workspaces

## uv Workspace Structure

uv supports workspaces via `[tool.uv.workspace]` in the root `pyproject.toml`.

### Root pyproject.toml

```toml
[project]
name = "my-monorepo"
version = "0.1.0"
requires-python = ">=3.12"

[tool.uv.workspace]
members = ["packages/*"]

[tool.uv.sources]
# Override sources for workspace members or external deps
my-lib = { workspace = true }
```

### Member pyproject.toml

```toml
[project]
name = "my-lib"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
    "httpx>=0.27",
    "pydantic>=2.0",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"
```

## Common Version Errors

### "No solution found" / "resolution impossible"

**Cause:** Two packages require incompatible versions of a dependency.
**Fix:** Check which packages conflict:

```bash
uv pip compile --verbose  # shows resolution trace
uv tree                   # show dependency tree
uv tree --invert <pkg>    # who depends on this package
```

Then update the constraint in the correct `pyproject.toml`.

### "requires-python mismatch"

**Cause:** Member declares `requires-python = ">=3.13"` but workspace is `>=3.12`.
**Fix:** Align requires-python across workspace. Usually update the root to match
the most restrictive member, or relax the member constraint.

### "package not found" with workspace sources

**Cause:** `[tool.uv.sources]` references a workspace member that isn't in `members`.
**Fix:** Add the member path to `[tool.uv.workspace].members`.

### Stale lock file

**Cause:** `pyproject.toml` changed but `uv.lock` wasn't updated.
**Fix:** Run `uv lock` to regenerate.

```bash
uv lock              # regenerate lock file
uv lock --upgrade    # upgrade all deps to latest compatible
uv lock --upgrade-package httpx  # upgrade single package
```

## Version Syntax

```toml
dependencies = [
    "httpx>=0.27",           # minimum version
    "httpx>=0.27,<1.0",      # range
    "httpx~=0.27.0",         # compatible release (>=0.27.0, <0.28.0)
    "httpx==0.27.0",         # exact pin (avoid unless necessary)
]
```

## uv-Specific Commands

```bash
uv add <package>          # add dep to current project
uv add --dev <package>    # add dev dep
uv remove <package>       # remove dep
uv lock                   # resolve and lock
uv sync                   # install from lock file
uv tree                   # show dep tree
uv pip list               # show installed packages
```

## Workspace vs Member — Where to Put What

| Config | Where |
|--------|-------|
| Python version constraint | Root `requires-python` (members inherit or override) |
| Shared dev tools (ruff, pytest) | Root `[dependency-groups]` |
| Package-specific deps | Member `[project].dependencies` |
| Source overrides | Root `[tool.uv.sources]` |
| Build system | Member level (each package has its own) |

## Key Difference from Rust

Unlike Cargo workspaces, uv workspaces don't have `[workspace.dependencies]` for
sharing version constraints. Each member declares its own dependencies. Version
unification happens at resolution time via the lock file, not at declaration time.

To share a version constraint, use `[tool.uv.sources]` in the root to pin a
specific source (workspace member, git repo, or local path).

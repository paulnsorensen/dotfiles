---
name: deps
description: Audit dependencies for unused packages, security issues, and stdlib alternatives.
allowed-tools: Read, Grep, Glob, Bash
argument-hint: "[focus area or leave blank for full audit]"
---

Audit dependencies: $ARGUMENTS

## Instructions

### 1. Detect Package Manager

Look for manifest files:
| File | Ecosystem | Lock File |
|------|-----------|-----------|
| `package.json` | npm/node | `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock` |
| `pyproject.toml` | python/uv | `uv.lock`, `poetry.lock` |
| `go.mod` | go | `go.sum` |
| `Cargo.toml` | rust | `Cargo.lock` |
| `Gemfile` | ruby | `Gemfile.lock` |

If multiple ecosystems exist, audit each.

### 2. Inventory

Read the manifest and list all dependencies, split by:
- **Production** dependencies
- **Dev** dependencies

### 3. Unused Detection

For each production dependency, search the codebase for actual imports/usage:

**Node:** Search for `require('{pkg}')`, `from '{pkg}'`, `import '{pkg}'`
**Python:** Search for `import {pkg}`, `from {pkg}`
**Go:** Search for `"{module}/{pkg}"`
**Rust:** Search for `use {pkg}::`

Flag any dependency with zero import matches as **POSSIBLY UNUSED**. Note: some packages are used implicitly (plugins, runtime deps, CLI tools). Mark these as LOW confidence.

### 4. Weight Check

For Node projects, if available:
```
npx howfat {package}     # or
npx package-size {package}
```

For all ecosystems, note packages that seem heavyweight for what they do:
- Full utility libraries when only one function is used (e.g., lodash for `_.get`)
- Frameworks pulled in for a single feature
- Packages that could be replaced by a few lines of stdlib

### 5. Stdlib Alternatives

For each dependency, briefly assess: could stdlib (or a language built-in) replace this?

Common candidates:
| Package | Stdlib Alternative |
|---------|-------------------|
| `lodash` | Native array/object methods |
| `moment`/`dayjs` | `Intl.DateTimeFormat`, `Temporal` |
| `uuid` | `crypto.randomUUID()` |
| `axios` | `fetch` |
| `chalk` | `node:util.styleText` |
| `dotenv` | `--env-file` flag |
| `path-to-regexp` | `URLPattern` |
| `requests` (py) | `urllib3` or `httpx` |
| `python-dotenv` | `os.environ` |

### 6. Security Quick Check

```bash
# Node
npm audit --json 2>/dev/null | head -50

# Python
uv pip audit 2>/dev/null || pip-audit 2>/dev/null

# Rust
cargo audit 2>/dev/null

# Go
govulncheck ./... 2>/dev/null
```

If audit tools aren't installed, note it and skip — don't install them.

### 7. Report

```
## Dependency Audit: {project}

### Summary
- Production deps: {N}
- Dev deps: {N}
- Possibly unused: {N}
- Stdlib replaceable: {N}
- Security issues: {N}

### Possibly Unused
| Package | Confidence | Notes |
|---------|------------|-------|
| {pkg}   | HIGH/LOW   | {why} |

### Stdlib Alternatives
| Package | Current Use | Alternative |
|---------|-------------|-------------|
| {pkg}   | {what for}  | {stdlib}    |

### Security
{audit results or "no audit tool available"}

### Recommendations
1. {highest-impact action}
2. {next action}
```

## What This Does NOT Do

- Does not install or remove packages
- Does not modify any files
- Does not install audit tools
- Does not upgrade dependencies (that's a separate task)

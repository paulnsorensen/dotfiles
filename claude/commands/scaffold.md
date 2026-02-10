---
name: scaffold
description: Scaffold a new domain slice following the Sliced Bread architecture pattern.
allowed-tools: Read, Write, Bash, Glob, Grep
argument-hint: "<slice-name> [language: ts|py|go|rs]"
---

Scaffold a new domain slice: $ARGUMENTS

## Instructions

### 1. Parse Arguments

Extract:
- **Slice name** — the domain concept (e.g., `orders`, `pricing`, `notifications`)
- **Language** — optional, detect from project if not specified. Check for `package.json` (ts), `pyproject.toml`/`uv.lock` (py), `go.mod` (go), `Cargo.toml` (rs).

### 2. Detect Project Layout

Find the existing domain directory by looking for common patterns:
- `src/domains/` or `src/domain/`
- `src/`
- `lib/`
- `pkg/` (Go)
- `crates/` (Rust)

If no domain directory exists, ask the user where slices should live.

### 3. Check for Conflicts

Verify the slice doesn't already exist. If it does, report what's there and ask what to do.

### 4. Scaffold the Slice

Create the minimal viable slice — two files following the Sliced Bread growth pattern ("start with one file per concept"):

**TypeScript:**
```
src/domains/{slice-name}/
├── index.ts          # Public API (the crust)
└── {slice-name}.ts   # Core concept
```

`index.ts`:
```typescript
export { } from './{slice-name}';
```

`{slice-name}.ts`:
```typescript
// Core {SliceName} domain logic
```

**Python:**
```
src/domains/{slice_name}/
├── __init__.py       # Public API (the crust)
└── {slice_name}.py   # Core concept
```

`__init__.py`:
```python
from .{slice_name} import *
```

`{slice_name}.py`:
```python
"""Core {SliceName} domain logic."""
```

**Go:**
```
pkg/{slicename}/
└── {slicename}.go    # Package is the public API
```

`{slicename}.go`:
```go
package {slicename}
```

**Rust:**
```
src/{slice_name}/
├── mod.rs            # Public API
└── {slice_name}.rs   # Core concept
```

### 5. Report

```
Scaffolded: {slice-name}
  Created: {list of files}
  Public API: {index file path}

Growth pattern reminder:
  1. Add logic to {core file}
  2. Extract sibling files when it gets crowded
  3. If a file needs helpers, it becomes a facade + subdirectory

Rules:
  - External code imports from the index only
  - Keep models pure (no infrastructure imports)
  - This slice imports nothing from sibling slices (use common/ or events)
```

## What NOT to Scaffold

- No test files (write tests when there's code to test)
- No README or docs
- No configuration files
- No abstract base classes or interfaces (YAGNI)
- No adapters or infrastructure (add when needed)

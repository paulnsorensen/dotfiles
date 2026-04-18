---
name: version-doctor
description: >
  Diagnose and fix library version mismatches, dependency conflicts, and build
  file inheritance issues. Use this skill when encountering version resolution
  failures, workspace inheritance problems, or when the user says "fix versions",
  "version mismatch", "dependency conflict", "why won't this build", or "update
  dependencies". Also trigger proactively when a build fails due to version
  constraints — the right fix is almost always updating a version number, not
  restructuring the build. If you catch yourself about to rewrite a build config
  or bypass workspace inheritance because of a version error, stop and use this
  skill instead.
allowed-tools: Bash, Agent, mcp__tilth__*
---

# version-doctor

Fix version mismatches by updating versions, not restructuring builds.

The #1 failure mode when AI encounters a build error: it treats a version mismatch
as "wrong approach" and restructures the entire build config. The correct response
is almost always: change one version number.

## Core Principle

**Version mismatch = fix the version. Not restructure the build.**

Build configs have inheritance chains (workspace → member). When a version conflict
appears, the inheritance is correct — the version is wrong. Respect the architecture.

## Protocol

### Step 1: Map the config chain

Read the full inheritance chain before touching anything:

```
workspace root config → intermediate configs → the file with the error
```

For each build system:

- **Rust**: `Cargo.toml` (workspace root) → member `Cargo.toml` files
- **Python**: `pyproject.toml` (workspace root with `uv`) → member packages
- **Node**: root `package.json` → workspace `package.json` files
- **Go**: `go.work` → member `go.mod` files
- **JVM**: `settings.gradle` + root `build.gradle` → subproject `build.gradle`

Read the relevant reference file from `references/` for the specific build system.

### Step 2: Diagnose

Classify the error:

| Error Type | Symptom | Fix |
|------------|---------|-----|
| **Version mismatch** | "expected X, found Y" | Update version constraint |
| **Missing dependency** | "not found" / "no matching" | Add to correct config level |
| **Inheritance broken** | Child duplicates parent config | Remove child override, use inheritance |
| **Yanked/removed version** | "version X not available" | Find latest compatible version |
| **Conflicting constraints** | "impossible to satisfy" | Unify constraints at workspace level |

### Step 3: Research (when needed)

If the correct version isn't obvious:

1. **Context7 first** — spawn a research agent to fetch current docs for the library:

   ```
   Use /fetch or Context7 to check: what is the latest version of <library>?
   What changed between version X and Y?
   ```

2. **Changelog/migration guide** — for major version bumps, check if there are
   breaking changes that require code changes alongside the version bump

3. **Compatibility matrix** — some libraries pin to specific ranges of their
   dependencies. Check the library's own build config for constraints.

### Step 4: Fix

Apply the minimum change:

1. **Update the version number** in the correct config file (usually workspace root)
2. **Run the lock file update** (`cargo update`, `uv lock`, `npm install`, `go mod tidy`)
3. **If code changes needed** (rare, only for major version bumps): make them, but
   flag to the user that this is a breaking change fix, not just a version bump

### Step 5: Verify

Run the build to confirm the fix works. Use `/make` if available, otherwise:

| Build System | Verify Command |
|-------------|----------------|
| Rust | `cargo check` |
| Python (uv) | `uv lock && uv run python -c "import <pkg>"` |
| Node | `npm install && npm run build` |
| Go | `go build ./...` |
| JVM | `gradle build` |

## What NOT to do

These are the panic responses that waste the user's time:

- **Don't bypass workspace inheritance** — if a member config inherits from workspace,
  don't copy everything into the member to "fix" a version issue
- **Don't create standalone configs** — replacing an inherited config with a standalone
  one breaks the project's build architecture
- **Don't downgrade to avoid conflicts** — find the version that satisfies all constraints,
  don't retreat to an old version that sidesteps the problem
- **Don't restructure the dependency tree** — if the workspace declares dep X at version 1.0
  and you need 2.0, update the workspace, don't fork the dep
- **Don't roll custom build scripts** — if the build tool has a config option, use it

## Output Format

Present findings as:

```
## Diagnosis
<what's wrong — one sentence>

## Root Cause
<which config file, which version constraint, why it conflicts>

## Fix
<exact change — file path, old value → new value>

## Verification
<command to run to confirm>
```

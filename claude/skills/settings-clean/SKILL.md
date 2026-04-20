---
name: settings-clean
model: haiku
context: fork
description: Clean up bloated .claude/settings.local.json by removing redundant, stale, and junk permission entries, and ensure hook-redirected skills are allowed. Use when the user says "clean settings", "prune settings", "settings cleanup", or invokes /settings-clean. Also trigger proactively when you notice a settings.local.json with more than 30 permission entries, or after extended sessions where many one-off Bash permissions have accumulated. This skill only touches settings.local.json (gitignored), never settings.json (committed).
allowed-tools: Read, Write, Bash(jq:*), Bash(cp:*), Bash(mkdir:*), Bash(mv:*), Bash(date:*)
---

# Settings Clean

Prune bloated `.claude/settings.local.json` files by removing permission entries that are redundant, stale, or junk — and ensure that skills referenced by hooks are actually allowed.

Claude Code's permission system only appends to `permissions.allow` — it never prunes — so these files grow unbounded. Meanwhile, hooks block legacy tools and redirect to skills that may not be in the allow list, creating a broken redirect loop.

## Step 1: Read Context

```
LOCAL:   .claude/settings.local.json     (in the current project root)
GLOBAL:  ~/.claude/settings.json          (user-wide settings)
HOOKS:   claude/hooks/*.js                (PreToolUse hooks — for hook-blocked detection)
SKILLS:  claude/skills/*/SKILL.md         (available skills — for missing skill detection)
```

If the local file doesn't exist or has no `permissions.allow`, skip to Step 6 (skill additions may still apply).

## Step 2: Classify Each Entry

Walk through every entry in the local `permissions.allow` array. Classify each into exactly one category, checking in this order (first match wins):

### JUNK — always remove

These entries are bugs or nonsense. They never match real commands.

| Pattern | Why it's junk |
|---|---|
| Contains `__NEW_LINE_` | Claude Code serialization bug for multi-line commands |
| `Bash(done)`, `Bash(fi)`, `Bash(then)`, `Bash(else)` | Shell keywords, not commands |
| `Bash(cd:*)` | Shell builtin, doesn't go through Bash tool |
| `Bash(for *)`, `Bash(if *)`, `Bash(while *)` | Shell keywords captured mid-compound-command |
| Exact duplicate of another entry in the same file | Redundant |

### HOOK-BLOCKED — permission is pointless because a hook blocks execution

If PreToolUse hooks exist, some Bash commands are blocked regardless of permissions. A permission entry for a blocked command just skips the user prompt — only for the hook to reject it anyway.

**From bash-guard.js:**

| Hook block | Matching allow entries | Hook redirects to |
|---|---|---|
| Legacy: `grep`, `egrep`, `fgrep` | `Bash(grep:*)` etc. | Grep tool, `/scout` |
| Legacy: `sed` | `Bash(sed:*)` | `/chisel`, Edit |
| Legacy: `awk` | `Bash(awk:*)` | `/chisel`, Edit |
| Legacy: `find` | `Bash(find:*)`, specific find commands | Glob, `/scout (fd)` |
| Install: `npm install` | `Bash(npm install:*)` | per-use approval |
| Install: `pnpm add/install` | `Bash(pnpm add:*)`, `Bash(pnpm install:*)` | per-use approval |
| Install: `yarn add` | `Bash(yarn add:*)` | per-use approval |
| Install: `pip install` | `Bash(pip install:*)` | per-use approval |
| Install: `cargo add` | `Bash(cargo add:*)` | per-use approval |
| Install: `go get` | `Bash(go get:*)` | per-use approval |
| Inline tests: `python3 -c` + import/assert | subset of `Bash(python3 -c:*)` | `/test-sandbox` |
| Dep cache grep | entries with `.cargo/registry`, `node_modules/` etc. | `/lookup`, `/fetch` |
| Heuristic: `cd && git` | `Bash(cd:*)` (already JUNK) | `/wt-git` |

Only flag entries where the hook would **always** block them. If a permission is broader than the hook pattern (e.g., `Bash(python3:*)` covers both blocked test patterns AND legitimate scripts), KEEP the permission.

### COVERED — remove if already handled

An entry is "covered" when a broader permission already exists, either in global settings or elsewhere in the same local file.

**Global coverage** — check if the local entry's command prefix matches a global wildcard:

1. Parse the local entry's first word after `Bash(` as the prefix
2. If global has `Bash(prefix:*)`, the local entry adds nothing

Examples:

- Local `Bash(git stash:*)` + Global `Bash(git:*)` → covered
- Local `Bash(which rustup:*)` + Global `Bash(which:*)` → covered
- Local `Bash(npm install:*)` + Global `Bash(npx:*)` → NOT covered (different prefix)

**Same-file coverage** — also applies to Bash and Read entries within the local file:

- `Read(//path/subdir/**)` is covered by `Read(//path/**)`
- `Bash(cargo check:*)` is covered by `Bash(cargo:*)`
- `Bash(python3 -c:*)` is covered by `Bash(python3:*)`

For non-Bash entries: check for exact match in global (e.g., local `Edit` + global `Edit` → covered).

### ONE-OFF — remove ephemeral debug commands

These are commands the user ran once during a session. They accumulate fast and will never be reused.

| Pattern | Example |
|---|---|
| Hardcoded absolute home path (`/Users/`, `/home/`, or `~/`) | `Bash(bash /Users/paul/Dev/dotfiles/claude/mcp/sync.sh ...)` |
| Pipe chains (`\|`) | `Bash(... 2>&1 \| grep -i ...)` |
| Command joiners (`;`, `&&`, `\|\|`) | `Bash(command -v cargo && cargo --version)` |
| Stderr redirects (`2>&1`, `2>/dev/null`) | Debug output capture |
| `Bash(bash -x ...)` | Debug tracing |
| `Bash(find ...)` with specific paths | `Bash(find ~/Dev/dotfiles/claude -type f ...)` |
| `Bash(python3 -c ...)` with inline code | One-off test snippets |
| Specific PR numbers or commit SHAs | `Bash(gh pr merge 395 --rebase ...)` |

**Exception**: Don't flag entries that are *just* a clean wildcard (e.g., `Bash(python3:*)`, `Bash(grep:*)`). The patterns above target verbose, specific command strings — not clean `tool:*` patterns.

### KEEP — intentional entries

Everything else stays:

- `Skill(*)` entries — user enabled these deliberately
- `LSP` — intentional
- `Bash(toolname:*)` wildcards not covered by global or same-file — project-specific
- Clean `Bash(toolname arg:*)` patterns that don't match one-off patterns
- `mcp__*` entries not in global
- `WebFetch(domain:*)` entries — intentional domain allowlists
- `Read()` entries not covered by a broader Read

## Step 3: Present Removal Results

**Always start with dry-run output**, regardless of whether the user said `--apply`.

Format a table grouped by category (see example in Step 7).

## Step 4: Recommend Deny Entries

Suggest `permissions.deny` entries that reinforce hook blocks. These act as belt-and-suspenders — if Claude's interactive approval re-adds a blocked command to allow, the deny list catches it.

```
Recommended deny entries (reinforces hook blocks):

  Legacy tools (use dedicated tools instead):
    "Bash(grep:*)"         → Grep tool or /scout
    "Bash(egrep:*)"        → Grep tool or /scout
    "Bash(fgrep:*)"        → Grep tool or /scout
    "Bash(sed:*)"          → /chisel (sd) or Edit
    "Bash(awk:*)"          → /chisel (sd) or Edit
    "Bash(find:*)"         → Glob tool or /scout (fd)

  Package installs (require per-use approval):
    "Bash(npm install:*)"  → approve individually
    "Bash(pnpm add:*)"     → approve individually
    "Bash(pnpm install:*)" → approve individually
    "Bash(yarn add:*)"     → approve individually
    "Bash(pip install:*)"  → approve individually
    "Bash(pip3 install:*)" → approve individually
    "Bash(cargo add:*)"    → approve individually
    "Bash(go get:*)"       → approve individually
```

## Step 5: Detect Missing Skills

Hooks redirect blocked commands to skills, but those skills need `Skill(name)` in the allow list or Claude will prompt for permission — defeating the smooth redirect.

### How to detect

1. **Scan available skills**: Read `claude/skills/*/SKILL.md` to find all skill names. If the skills directory doesn't exist in the current project, check `~/Dev/dotfiles/claude/skills/` (the canonical source).

2. **Map hook redirects to required skills**: Each hook block implies a skill that should be allowed:

| Hook blocks | Required skill |
|---|---|
| `grep`, `egrep`, `fgrep` | `Skill(scout)` |
| `sed`, `awk` | `Skill(chisel)` |
| `find` | `Skill(scout)` |
| `python3 -c` tests | `Skill(test-sandbox)` |
| dep cache grep, doc+grep | `Skill(lookup)`, `Skill(fetch)` |
| find+grep chains | `Skill(trace)`, `Skill(lookup)` |
| `cd && git` | `Skill(wt-git)` |
| `gh pr create --body` | `Skill(gh)` |

1. **Check what's missing**: Compare available skills + hook-required skills against the current allow list. Report missing ones, prioritizing hook-critical skills first.

### Present as two groups

```
Missing skills — hook-critical (redirect won't work without these):
  + Skill(scout)          ← grep/find hooks redirect here
  + Skill(chisel)         ← sed/awk hooks redirect here
  + Skill(test-sandbox)   ← python3 -c hook redirects here
  + Skill(lookup)         ← dep cache/doc grep hooks redirect here
  + Skill(fetch)          ← dep cache/doc grep hooks redirect here
  + Skill(trace)          ← find+grep chain hook redirects here

Missing skills — available but not allowed:
  + Skill(diff)
  + Skill(de-slop)
  + Skill(make)
  + Skill(self-eval)
  ...
```

## Step 6: Present Full Summary

Combine all recommendations:

```
Settings Clean: .claude/settings.local.json
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

REMOVALS:
  JUNK:           5 entries
  HOOK-BLOCKED:   2 entries
  COVERED:       10 entries
  ONE-OFF:       37 entries
  ─────────────────────────
  Total removed: 54 entries

KEPT:            33 entries

DENY (recommended):     12 entries  (reinforces hooks)
SKILLS (recommended):   20 entries  (7 hook-critical, 13 available)

Net: 87 allow → 33 allow + 20 skills + 12 deny
```

## Step 7: Apply (only when asked)

The user must explicitly say `--apply`, "apply", "do it", "clean it", or similar.

When applying:

1. **Backup** the current file:

   ```bash
   mkdir -p ~/.local/state/dotfiles/backups
   cp .claude/settings.local.json ~/.local/state/dotfiles/backups/settings.local.json.$(date +%Y%m%d-%H%M%S)
   ```

2. **Write** the cleaned file, preserving:
   - All non-`permissions` keys (`sandbox`, `hooks`, `enabledMcpjsonServers`, etc.)
   - The kept allow entries + new Skill entries, sorted alphabetically
   - User-approved deny entries
   - Original JSON formatting (2-space indent)

3. **Report** the result:

   ```
   Backed up to: ~/.local/state/dotfiles/backups/settings.local.json.20260319-143022
   Wrote: .claude/settings.local.json
     allow: 53 entries (33 kept + 20 skills added, was 87)
     deny:  12 entries (new)
   ```

## Important

- **Never touch `settings.json`** (the committed project settings). Only `settings.local.json`.
- **When in doubt, KEEP.** False negatives (keeping junk) are harmless; false positives (removing something needed) cause permission prompts.
- **No confirmation loops.** Show the dry-run, wait for the user to say apply.
- **Hook detection is optional.** If no hooks exist, skip HOOK-BLOCKED and deny recommendations. The removal and skill-addition logic still works independently.
- **Skill detection is best-effort.** If the skills directory can't be found, skip Step 5. The removal logic still works independently.

## Gotchas

- Removing a Bash permission entry forces re-approval next time it's needed — when in doubt, keep it
- Running during an active session that's accumulating permissions can cause immediate re-addition
- Pipe characters in regex-style entries need careful matching — don't break valid patterns
- Hook-redirected skills need their permissions preserved — check hooks before pruning

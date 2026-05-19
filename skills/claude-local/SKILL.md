---
name: claude-local
model: sonnet
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(grep:*), Bash(test:*), Bash(touch:*), Bash(mkdir:*), Bash(printf:*), Glob
description: >
  Distill the user's global ~/.claude/CLAUDE.md into a project-scoped
  CLAUDE.local.md (gitignored) for repos they're contributing to but
  don't own. Detects the project's languages and build system, keeps
  only the relevant subset of global preferences (coding principles,
  complexity budget, skill delegation table, self-eval checklist,
  language-gated style notes), drops the personal-flair sections and
  architectural opinions that shouldn't bleed into a contributed repo.
  Ensures CLAUDE.local.md is covered by the user's GLOBAL gitignore —
  never the project's .gitignore — so the contribution stays clean. Use
  when the user says "set up CLAUDE.local", "scaffold local claude
  config", "drop my preferences in this repo", "I'm contributing to
  this repo and want my preferences applied", "claude-local.md", or
  invokes /claude-local. Also use proactively when the user opens a
  shell in an unfamiliar repo and says they want to start contributing.
---

# claude-local

Tailor the user's global Claude Code preferences to *this* project and write
them to a `CLAUDE.local.md` that the global gitignore covers. The output is a
slim, project-relevant overlay — not a copy of `~/.claude/CLAUDE.md`.

## Why this exists

The global `~/.claude/CLAUDE.md` is tuned for the user's own work —
personal communication style, owned-architecture rules, early-development
stances. When the user contributes to someone else's
repo they want their *engineering* preferences applied (coding principles,
skill delegation, self-eval) without dragging in the personal flair or
architectural opinions that don't apply to a codebase they don't own.

Two non-negotiables:

1. **Never modify the project's own files.** No edits to the project's
   `CLAUDE.md`, `AGENTS.md`, or `.gitignore`. The point is a clean,
   gitignored personal overlay.
2. **Re-read the global on every invocation.** Don't hard-code the
   distillation in this skill — the user's preferences evolve. Read
   `~/.claude/CLAUDE.md` fresh each time so updates flow through.

## Workflow

### 1. Locate the project root

The output goes at the project root (top of the git repo), not the cwd.

```bash
git rev-parse --show-toplevel
```

If that fails (not a git repo), tell the user and stop — `CLAUDE.local.md`
only makes sense when there's a git boundary to scope it to.

### 2. Check for an existing CLAUDE.local.md

```bash
test -f "$REPO_ROOT/CLAUDE.local.md"
```

If it exists, ask the user: refresh (regenerate from current global), keep
(stop), or overwrite (treat as new). Don't silently clobber — the user may
have hand-edited it.

### 3. Detect project context

Read these signals to drive the distillation. Glob from the repo root:

| Signal | Implies |
|--------|---------|
| `Cargo.toml` | Rust |
| `package.json` (+ `tsconfig.json`) | TypeScript |
| `package.json` (no tsconfig) | JavaScript |
| `pyproject.toml` / `setup.py` / `requirements.txt` | Python |
| `go.mod` | Go |
| `Gemfile` | Ruby |
| `pom.xml` / `build.gradle*` | Java / Kotlin |
| `composer.json` | PHP |
| `mix.exs` | Elixir |
| `*.csproj` / `*.sln` | C# / .NET |

A project can be multi-language. Capture every language signal you find.
Note the build/runtime tooling you observe (uv vs pip, pnpm vs npm vs yarn,
cargo vs bazel) so the output references what the project actually uses.

### 4. Read the global preferences fresh

```
Read("~/.claude/CLAUDE.md")
```

Do not trust any cached summary in this skill. The global file is the
source of truth.

### 5. Distill — what stays, what goes

Apply these rules. They aren't a checklist to copy verbatim; they're the
judgment to bring.

#### Always keep

- **Coding principles.** Input validation, fail-fast, loose coupling,
  YAGNI, real-world models, immutable patterns. These are language- and
  project-agnostic and travel everywhere.
- **Operational rules.** Skill-over-bash delegation (`cheez-search` over
  `grep`, `cheez-read` over `cat`, `cheez-write` over `sed`, `jq`/`yq`
  over inline `python3 -c`, `gh` over raw GitHub API), CLI tools
  (jq/yq/tokei/duckdb), agent permission model (bypassPermissions ≠ Bash
  bypass), agent nesting limits. These apply in any repo.
- **Self-evaluation guidance.** The brief `/self-eval` reference and its
  8-item anti-pattern summary (sycophancy, premature completion, dismissing
  failures, hedging, scope reduction, false confidence, AI slop, weak
  assertions). Universal.
- **Build system rules.** "Fix the version, don't restructure the build"
  — this is hard-won and applies to any project's deps.

#### Language-gate (include only if the project uses the language)

- **Python preference (`uv`)** — only include if you saw a `pyproject.toml`,
  `setup.py`, or `requirements.txt`.
- **Code style entries** — keep only the conventions for languages
  actually present. A pure-Rust project doesn't need the JS/TS camelCase
  rule.

#### Drop entirely (these are personal, not project-relevant)

- **Communication style** — the cheese / Dune / Mad Max flair. This is a
  personal-conversation preference. Even though `CLAUDE.local.md` is
  gitignored, a stray `git add -f` or grep across `$HOME` could surface it
  in a contributed repo's history. Keep the flair scoped to the global file.
- **Sliced Bread architecture** — the user's preferred file layout. In a
  contributed repo, the project's own structure is authoritative; the
  user shouldn't push a personal architecture on a codebase they don't
  own.
- **Early Development Stance** — "no backward compatibility concerns" only
  applies to the user's own unreleased projects. A contributed repo
  almost certainly has users.
- **Workflow / Cheddar Flow** beyond a brief reference. The full skill
  catalog is in the global file; the local overlay just needs to remind
  Claude that `/age`, `/cure`, `/respond`, `/de-slop`, and
  `/tdd-assertions` exist and are preferred. For autonomous flows on
  large changes, `/ultracook` chains cook → press → age → cure.
- **Troubleshooting one-liners** (`/go`, `/lsp`) — meta-tool
  state, irrelevant to any project.
- **RTK** — the rtk proxy is a personal tooling layer; it's auto-applied
  by hooks regardless and doesn't need to be repeated in a project file.

### 6. Write CLAUDE.local.md

Write to `<repo_root>/CLAUDE.local.md`. Use this template — keep it
compact (target: 60-120 lines, never longer than 200). Bullets, not
prose.

```markdown
# CLAUDE.local.md

Local Claude Code overlay — gitignored personal preferences scoped to
this repo. Not part of the project's instructions; this file is only
for the user's personal Claude Code session. Source: `~/.claude/CLAUDE.md`
(distilled <YYYY-MM-DD>).

## Project context

- **Languages:** <detected>
- **Build/runtime:** <detected>

## Engineering principles

<short bulleted list — coding principles>

## Complexity budget

<copied verbatim — it's already terse>

## Code style

<only the languages this project uses>

## Skill delegation

<the table, trimmed to tools relevant here — keep cheez-* always, keep
language-specific tooling only when applicable>

## Self-evaluation checklist

<the 8-item scan, one line each>

## Workflow shortcuts

<brief reference: /age, /cure, /respond, /de-slop, /tdd-assertions —
no full descriptions; these are reminders for Claude>

## Build system

- Fix versions, don't restructure builds.
- Read workspace/root config before modifying child build files.
- Use `/version-doctor` for dependency conflicts.
```

Adapt section headings to what's actually relevant — don't include a
"Code style" section with no content if the project's language wasn't
covered in the global file.

### 7. Cover with the global gitignore

`CLAUDE.local.md` must be ignored by Git but **not** via the project's
`.gitignore` (that would commit the user's preference for ignoring it).
Use the global excludes file.

```bash
# 1. Find or create the global excludes file
EXCLUDES="$(git config --global --get core.excludesfile || echo "")"
if [ -z "$EXCLUDES" ]; then
  EXCLUDES="$HOME/.config/git/ignore"
  mkdir -p "$(dirname "$EXCLUDES")"
  touch "$EXCLUDES"
  git config --global core.excludesfile "$EXCLUDES"
fi

# 2. Add CLAUDE.local.md if not already present
if ! grep -qxF "CLAUDE.local.md" "$EXCLUDES"; then
  printf '\n# Personal Claude Code overlay (claude-local skill)\nCLAUDE.local.md\n' >> "$EXCLUDES"
fi

# 3. Verify Git actually ignores the new file
git -C "$REPO_ROOT" check-ignore CLAUDE.local.md
```

If `git check-ignore` returns non-zero (file not ignored), surface the
issue and walk through possible causes — most likely the project has a
`!CLAUDE.local.md` un-ignore rule, or `core.excludesfile` is set to
something the user doesn't expect. Don't silently move on.

### 8. Report

Tell the user:

- Where `CLAUDE.local.md` was written (full path).
- Which sections you kept and which you dropped, with one-line reasons
  for non-obvious calls (e.g., "dropped Python preference — no
  `pyproject.toml` found").
- That the file is covered by `<excludes-file-path>` and verified
  ignored.

## What this skill never does

- **Never** edit the project's `CLAUDE.md`, `AGENTS.md`, `.gitignore`, or
  any other tracked file in the contributed repo.
- **Never** include the cheese / Dune / Mad Max communication style in
  the output.
- **Never** add `CLAUDE.local.md` to the project's `.gitignore` — that
  would be a tracked change suggesting the project should know about
  this file. Use the user's global excludes.
- **Never** hard-code a distilled snapshot in this skill. The
  `~/.claude/CLAUDE.md` re-read is the whole point — it lets the user
  edit their global preferences and have updates flow through on the
  next invocation.

## Idempotency

Running this skill twice on the same repo with no global changes should
produce a `CLAUDE.local.md` byte-identical (modulo the timestamp on the
"distilled" line) to the first run. If the user has hand-edited the
file, ask before regenerating — don't clobber their tweaks.

## Edge cases

- **Multi-language monorepo:** include style/tooling for every language
  detected; mark which is primary if it's obvious from line count or
  directory weight.
- **Project's `CLAUDE.md` already in scope:** `CLAUDE.local.md` is
  *additive* — Claude Code reads both. The local overlay should not
  contradict the project's instructions; if there's a clash, the
  project wins. Note this at the top of the output file.
- **Repo is the user's own dotfiles or a project they own:** the user
  probably wants the full global preferences, not a distillation.
  Check whether the repo path matches `~/Dev/dotfiles` or contains a
  CLAUDE.md that already imports `~/.claude/CLAUDE.md` — if so, ask
  before generating; the overlay may be redundant.
- **No `~/.claude/CLAUDE.md` exists:** stop and tell the user. There's
  nothing to distill from.

# Output template + gitignore wiring

## CLAUDE.local.md template

Write to `<repo_root>/CLAUDE.local.md`. Keep it compact (target: 60-120
lines, never longer than 200). Bullets, not prose. Adapt section headings to
what's actually relevant — don't include a "Code style" section with no
content if the project's language wasn't covered in the global file.

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

## Workflow shortcuts

<brief reference: /age, /cure, /respond, /de-slop —
no full descriptions; these are reminders for Claude>

## Build system

- Fix versions, don't restructure builds.
- Read workspace/root config before modifying child build files.
- Use `/version-doctor` for dependency conflicts.
```

## Global gitignore wiring

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

# Settings prune mode

Review bloated .claude/settings.local.json permission entries.
Only settings.local.json may change. Never change settings.json.

Claude Code appends permissions.allow entries, so these files grow.
Review entries against current tool-reroute behavior before recommending removal.

## Read-only contract

Always start with a dry-run report. The default is read-only.
Apply the authorization rule from harness-doctor before any write.

## Step 1: Read context

    LOCAL:  .claude/settings.local.json
    GLOBAL: ~/.claude/settings.json
    HOOKS:  agents/lib/tool-reroute.js

If the local file does not exist or has no permissions.allow, report that state.

## Step 2: Classify each entry

Walk through every permissions.allow entry.
Assign exactly one category in this order.

### JUNK

Remove entries that never match real commands:

| Pattern | Reason |
|---|---|
| Contains __NEW_LINE_ | Claude Code serialization bug |
| Bash(done), Bash(fi), Bash(then), Bash(else) | Shell keywords |
| Bash(cd:*) | Shell builtin |
| `Bash(for *)`, `Bash(if*)`, `Bash(while *)` | Shell keywords |
| Exact duplicate in the same file | Redundant |

### COVERED

Remove an entry when a broader permission already exists in global settings or
the same local file.

For Bash entries, compare the first command prefix.
For Read entries, compare path globs.
For other entries, compare exact matches.

Keep an entry when its prefix or path is not covered.

### ONE-OFF

Remove specific commands that represent temporary debugging:

| Pattern | Example |
|---|---|
| Hardcoded home path | A command containing /Users/, /home/, or ~/ |
| Pipe chain | A command containing a pipe |
| Command joiner | A command containing `;`, `&&`, or \|\| |
| Stderr redirect | A command containing 2>&1 or 2>/dev/null |
| Debug tracing | Bash(bash -x ...) |
| Specific path search | Bash(find ...) with a specific path |
| Inline script | Bash(python3 -c ...) |
| Specific PR or commit | A command containing a PR number or commit SHA |

Do not remove clean tool wildcards such as `Bash(python3:*)` or `Bash(grep:*)`.

### KEEP

Keep intentional entries that are not junk, covered, or one-off.
Keep Skill entries unless the user identifies them as stale.
Keep MCP, WebFetch, and Read entries without coverage.

## Step 3: Account for current tool reroute behavior

Read agents/lib/tool-reroute.js before classifying tool permissions.
The hook routes calls at runtime. It does not imply a redirect-to-skill table.

| Input | Behavior |
|---|---|
| Clean standalone grep, rg, ag, or ack | Rewrite to tilth |
| find with only -name or -path | Rewrite to tilth |
| cd path followed by && git | Rewrite to wt-git |
| Bare cat with one file | Rewrite to tilth |
| Grep or Glob tool | Deny and recommend tilth search |
| Repository write redirect | Deny and recommend tilth_write |
| Other Bash calls | Delegate to rtk |

Only clean shapes are rewritten.
Pipelines, redirects, semantic flags, and regex patterns delegate instead.

Do not add a skill permission because a reroute exists.
Add a skill permission only for a current user workflow.

## Step 4: Present the dry-run

Report names and counts.
Do not print permission values or complete settings files.

    Settings Clean: .claude/settings.local.json
    REMOVALS:
      JUNK: <count>
      COVERED: <count>
      ONE-OFF: <count>
      Total removed: <count>
    KEPT: <count>
    Skill changes: report only when a current user workflow requires them

## Step 5: Apply only after explicit authorization

The user must explicitly authorize this specific repair in the current turn.
An audit or recommendation does not authorize a write.

When authorized:

1. Back up settings.local.json.
2. Write only the reviewed permission changes.
3. Preserve non-permission keys and approved entries.
4. Report the backup path and resulting counts.

## Important

- Never touch settings.json.
- Keep uncertain entries.
- Show the dry-run before any write.
- Run hook analysis only when hook files exist.
- Report missing source files without changing them.
- Stop if an active session immediately re-adds entries.

# Drift audit — mechanics reference

This reference defines read-only comparisons for /harness-doctor.
The wiki defines current ownership. Read architecture/config-drift.md first.

## Read-only contract

The audit does not write live files. It does not run deployment or apply commands.
It does not publish GitHub issues or wiki entries. The authorization rule below applies
to every repair, issue publication, and wiki write.

**Authorization rule:** make a change only when the user explicitly authorizes that
specific action in the current turn. An audit, diagnosis, or recommendation does not
authorize a change.

Do not invoke a deployment renderer against a live target. Do not use retired targeting flags or
retired file-reader names. Never print live values or raw file differences.

## Ownership and target inputs

| Harness | Owner | Live inputs |
|---|---|---|
| Claude | chezmoi/dot_claude/modify_settings.json, chezmoi/.chezmoidata/claude.yaml, plugin overlays, and chezmoi/.chezmoiscripts/run_onchange_after_sync-claude-mcps.sh.tmpl | ~/.claude/settings.json and ~/.claude.json |
| Codex | chezmoi/private_dot_codex/modify_private_config.toml from chezmoi/.chezmoidata/codex.yaml; sync_codex_chezmoi_sources assembles shared hooks | ~/.codex/config.toml, ~/.codex/hooks.json |
| Cursor | User-owned live files and declared Cursor plugin projections | ~/.cursor/mcp.json, ~/.cursor/hooks.json |
| Copilot | Chezmoi templates and declared profile projections | ~/.copilot/mcp-config.json, ~/.copilot/hooks/ |
| OMP | chezmoi/.chezmoidata/omp.yaml and dot_omp/private_agent/modify_config.yml | ~/.omp/agent/config.yml, when OMP is in scope |

Claude settings ownership includes static settings, Claude registry keys, and
gate-filtered native plugin overlays. Codex overlays declared keys and MCP servers
while preserving CLI runtime tables. Cursor and Copilot live files remain user-owned.

## Grounding and provenance

Read the wiki before repository inspection:

    ground repo:dotfiles:wiki "config drift harness ownership"
    read_markdown repo:dotfiles:wiki architecture/config-drift.md
    read_markdown repo:dotfiles:wiki architecture/chezmoi-authoritative-codex.md

Use repository history only to prove migration provenance:

    git -C "$DOTFILES_DIR" log --oneline -20 -- agents/ chezmoi/ profiles/
    git -C "$DOTFILES_DIR" log --oneline --grep='migration\|settings\|hook' -20

Define the repository before any optional issue check:

    REPO="${REPO:-paulnsorensen/dotfiles}"

## Redacted snapshots

Report key paths, entry names, and counts only. Never print setting values.

    jq -r '[paths(scalars) | map(select(type == "string")) | join(".")] | sort[]' "$HOME/.claude/settings.json"
    jq -r '.mcpServers // {} | keys[]' "$HOME/.claude.json"
    yq -p=toml -o=json '.' "$HOME/.codex/config.toml" | jq -r '[paths(scalars) | map(select(type == "string")) | join(".")] | sort[]'
    jq -r '[paths(scalars) | map(select(type == "string")) | join(".")] | sort[]' "$HOME/.codex/hooks.json"
    jq -r '.mcpServers // {} | keys[]' "$HOME/.cursor/mcp.json"
    jq -r '.mcpServers // {} | keys[]' "$HOME/.copilot/mcp-config.json"
    yq -p=yaml -o=json '.' "$HOME/.omp/agent/config.yml" | jq -r '[paths(scalars) | map(select(type == "string")) | join(".")] | sort[]'

Skip a missing optional file. Record only the path and parser error.

## Semantic owner comparisons

Create one temporary directory. Each comparison stores normalized owner data in TMP and emits only names or paths:

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    normalize_scalars() {
        jq -S '[paths(scalars) as $p
          | {path: ($p | map(tostring) | join(".")), value: getpath($p)}]
          | sort_by(.path)' "$1"
    }

    compare_scalars() {
        jq -n --slurpfile owner "$1" --slurpfile live "$2" '
          ($owner[0] | map({key: .path, value: .value}) | from_entries) as $o
          | ($live[0] | map({key: .path, value: .value}) | from_entries) as $l
          | (($o | keys_unsorted) + ($l | keys_unsorted) | unique[]) as $path
          | select((($o | has($path)) != ($l | has($path)))
              or (($o | has($path)) and ($o[$path] != $l[$path])))
          | $path'
    }

    normalize_mcps() {
        jq -S '[. // {} | to_entries[] | {name: .key, config: .value}]
          | sort_by(.name)' "$1"
    }

    normalize_claude_mcps() {
        jq -S '[. // {} | to_entries[] |
          {name: .key, config: (
            .value + {
              type: (.value.type // "stdio"),
              command: .value.command,
              args: (.value.args // []),
              env: (.value.env // {})
            }
          )}] | sort_by(.name)' "$1"
    }

    compare_named() {
        jq -n --slurpfile owner "$1" --slurpfile live "$2" '
          ($owner[0] | map({key: .name, value: .config}) | from_entries) as $o
          | ($live[0] | map({key: .name, value: .config}) | from_entries) as $l
          | (($o | keys_unsorted) + ($l | keys_unsorted) | unique[]) as $name
          | select((($o | has($name)) != ($l | has($name)))
              or (($o | has($name)) and ($o[$name] != $l[$name])))
          | $name'
    }

    CHEZMOI_SOURCE_DIR="$DOTFILES_DIR/chezmoi" sh "$DOTFILES_DIR/chezmoi/dot_claude/modify_settings.json" < "$HOME/.claude/settings.json" |
      normalize_scalars - > "$TMP/claude-owner-scalars"
    normalize_scalars "$HOME/.claude/settings.json" > "$TMP/claude-live-scalars"
    compare_scalars "$TMP/claude-owner-scalars" "$TMP/claude-live-scalars"

    yq -o=json '.claude.mcps // {}' "$DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml" |
      normalize_claude_mcps - > "$TMP/claude-owner-mcps"
    jq -S '.mcpServers // {}' "$HOME/.claude.json" |
      normalize_claude_mcps - > "$TMP/claude-live-mcps"
    compare_named "$TMP/claude-owner-mcps" "$TMP/claude-live-mcps"

These commands compare Claude scalar values and MCP command, argument, and option values.
They emit differing key paths or MCP names only.

    CHEZMOI_SOURCE_DIR="$DOTFILES_DIR/chezmoi" sh "$DOTFILES_DIR/chezmoi/private_dot_codex/modify_private_config.toml" < "$HOME/.codex/config.toml" |
      yq -p=toml -o=json '.' |
      normalize_scalars - > "$TMP/codex-owner-scalars"
    yq -p=toml -o=json '.' "$HOME/.codex/config.toml" |
      normalize_scalars - > "$TMP/codex-live-scalars"
    compare_scalars "$TMP/codex-owner-scalars" "$TMP/codex-live-scalars"

    yq -o=json '.codex.mcps // {}' "$DOTFILES_DIR/chezmoi/.chezmoidata/codex.yaml" |
      normalize_mcps - > "$TMP/codex-owner-mcps"
    yq -p=toml -o=json '.' "$HOME/.codex/config.toml" |
      jq -S '[.mcp_servers // {} | to_entries[] | {name: .key, config: .value}]
        | sort_by(.name)' > "$TMP/codex-live-mcps"
    compare_named "$TMP/codex-owner-mcps" "$TMP/codex-live-mcps"

Compare only declared Codex paths. Treat projects, hooks.state, marketplaces,
plugins, and other CLI runtime paths as preserved local state.

## Codex hook comparison

The registry and shared assembly own Codex hook basenames. Compare names only:

    yq -o=json '.hooks // {} | to_entries[] |
      select((.value.harnesses // ["claude", "codex"]) | index("codex")) |
      .value.script // empty' "$DOTFILES_DIR/agents/hooks/registry.yaml" |
      jq -r 'split("/") | last' | sort > "$TMP/codex-owner-hooks"

    jq -r '.. | objects | .command? // empty | strings |
      select(contains(".codex/hooks/")) |
      split(".codex/hooks/")[1] | split(" ")[0] | rtrimstr("\"")' "$HOME/.codex/hooks.json" |
      sort > "$TMP/codex-live-hooks-json"

    yq -p=toml -o=json '.' "$HOME/.codex/config.toml" |
      jq -r '.. | objects | .command? // empty | strings |
        select(contains(".codex/hooks/")) |
        split(".codex/hooks/")[1] | split(" ")[0] | rtrimstr("\"")' |
      sort > "$TMP/codex-live-hooks-toml"

    comm -3 "$TMP/codex-owner-hooks" "$TMP/codex-live-hooks-json"
    comm -12 "$TMP/codex-live-hooks-json" "$TMP/codex-live-hooks-toml"

A name in both live hook outputs indicates duplicate legacy wiring. Report the name
only. Do not print its command, arguments, or environment.

## Intended projections

Do not run agent-profile deployment or compilation for this audit. Those operations
can install plugins and do not model global settings ownership.

Copilot's chezmoi template can render into TMP without applying it:

    chezmoi --source "$DOTFILES_DIR/chezmoi" execute-template < "$DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl" > "$TMP/copilot-owner.json"
    jq -r '.mcpServers // {} | keys[]' "$TMP/copilot-owner.json" | sort > "$TMP/copilot-owner-mcps"
    jq -r '.mcpServers // {} | keys[]' "$HOME/.copilot/mcp-config.json" | sort > "$TMP/copilot-live-mcps"
    comm -3 "$TMP/copilot-owner-mcps" "$TMP/copilot-live-mcps"

Cursor and Copilot extras remain user-owned. Compare only declared plugin names,
MCP names, hook names, and counts. Do not classify every live-only entry as stale.

When OMP is in scope, run its modify script into TMP and compare normalized values:

    CHEZMOI_SOURCE_DIR="$DOTFILES_DIR/chezmoi" sh "$DOTFILES_DIR/chezmoi/dot_omp/private_agent/modify_config.yml" < "$HOME/.omp/agent/config.yml" |
      yq -p=yaml -o=json '.' |
      normalize_scalars - > "$TMP/omp-owner-scalars"
    yq -p=yaml -o=json '.' "$HOME/.omp/agent/config.yml" |
      normalize_scalars - > "$TMP/omp-live-scalars"
    compare_scalars "$TMP/omp-owner-scalars" "$TMP/omp-live-scalars"

## Classification checklist

Classify a difference only when evidence supports it:

1. Stale remnant: the owner abandoned the entry, and history proves the migration.
2. Dotfiles bug: source validation or the intended projection is wrong.
3. Expected local: live-only content has no repository provenance.
4. Needs your call: the evidence supports more than one class.

Check these dotfiles-bug cases:

- A hook script is missing.
- A hook event is absent from HOOK_EVENTS_VALID.
- A Codex hook command uses a relative path from a user-level config.
- A managed Codex hook basename appears in both hooks.json and legacy TOML hooks.
- An MCP uses an unset variable without an optional marker.
- A skill directory lacks SKILL.md, or a body_path is missing.
- A run_onchange hash omits a file that the script reads.
- The wiki index cannot rebuild.

## Repair and issue publication

Do not perform either action during the default audit. Apply the authorization rule
above before any action.

After explicit authorization, state the exact file, command, and expected effect first.
Use the tested owner mechanism. Never hand-edit a rendered target.

After explicit authorization for issue publication, deduplicate first:

    gh issue list --repo "$REPO" --state open --label harness-doctor --json number,title

Ask for confirmation of each novel issue body before using gh issue create.
If GitHub is unavailable, save proposed bodies under .cheese/harness-doctor/ only
after explicit authorization for issue preparation.

## Misplaced project knowledge

When .hallouminate/wiki/ exists, inspect project memory for type: project.
Report candidates under Needs your call. Do not delete or publish an issue for them.
wiki-curator can migrate them after the user approves.

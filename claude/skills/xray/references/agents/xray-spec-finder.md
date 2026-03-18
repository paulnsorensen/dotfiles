# xray-spec-finder — Spec and Ticket Search

You find specs, issues, and PRs related to a module so the analyst understands
the intent behind the code.

## Agent Structure

The analyst spawns TWO parallel haiku agents from these instructions:

### Local Spec Agent

**Model**: haiku
**Tools**: Read, Grep, Glob

1. Search `.claude/specs/` for files mentioning the module name or key symbols:
   ```
   Grep: {module_name} in .claude/specs/
   Grep: {key_symbol_1} in .claude/specs/
   ```
2. Read matching spec files
3. Extract:
   - Spec title and status
   - Acceptance criteria (as a checklist)
   - Any non-goals or constraints that affect verification
4. Return structured findings:
   ```
   ## Local Specs
   ### {spec-title} (.claude/specs/{filename})
   Status: {draft|approved|implemented}
   Acceptance Criteria:
   - [ ] {criterion 1}
   - [ ] {criterion 2}
   Constraints: {any relevant constraints}
   ```

If no specs found, return "No local specs found for {module_name}."

### GitHub Agent

**Model**: haiku
**Tools**: Bash (gh CLI only)

1. Search GitHub issues mentioning the module:
   ```bash
   gh issue list --search "{module_name}" --limit 5 --json number,title,state,body
   ```
2. Search GitHub PRs mentioning the module:
   ```bash
   gh pr list --search "{module_name}" --state all --limit 5 --json number,title,state,body
   ```
3. For each match, extract:
   - Number, title, state
   - Key quotes from the body (max 2 sentences per item)
4. Return structured findings:
   ```
   ## GitHub Context
   ### Issues
   - #{number}: {title} ({state}) — "{key quote}"
   ### PRs
   - #{number}: {title} ({state}) — "{key quote}"
   ```

If GitHub is unavailable (auth failure, sandbox), return
"GitHub search unavailable — continuing with local specs only."
This is NOT a blocking error.

## Output Contract

Both agents return markdown-structured findings. The analyst synthesizes
these into the node analysis. Spec acceptance criteria are particularly
important — they drive behavioral coverage scoring.

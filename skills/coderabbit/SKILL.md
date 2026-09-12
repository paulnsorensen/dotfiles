---
name: coderabbit
model: sonnet
effort: medium
description: >
  Audit or configure CodeRabbit settings with evidence from repository files,
  pull requests, and current primary documentation. Use when the user says
  "configure CodeRabbit", "review .coderabbit.yaml", "set up CodeRabbit",
  "audit CodeRabbit settings", or "is CodeRabbit covering X". Do NOT use to
  run a CodeRabbit CLI review or autofix, or to fix review comments on a PR
  (/land, /affinage).
license: MIT
metadata:
  author: paulnsorensen
---

# CodeRabbit configuration

Audit by default; an audit is read-only.
Treat setup as a narrowly scoped configuration change.

**Iron Law:** no configuration claim or edit is valid without current evidence for its scope and effective behavior.

## Inputs

The text after the skill name names the request: `audit [PR <n>]` or `set up` / `update <change>`.
A bare invocation is an audit of the current repository.

1. Read the repository instructions. Read the repository wiki when one exists; do not require one.
2. When the request names a pull request, record the exact head SHA and base branch.
3. Read the current `.coderabbit.yaml`, repository settings, and inherited (organization) configuration evidence.
4. Read the build, test, and CI configuration that defines repository behavior.
5. Take the main branch, the language, and the path layout from evidence, not assumption.
6. Preserve explicit user decisions about scope, severity, presets, branches, and enforcement.
7. Use `/briesearch` when available for current documentation; else fetch the primary references below.
8. Treat every default as dated; confirm it against current documentation.

Done when: the effective configuration source (file, inherited, or UI) is named, and the PR head and base are recorded when a PR is in scope.

## Audit

Separate three claims and report each on its own: schema validity, rule quality, and evidence that a review completed.

### Schema validity

1. Prefer `coderabbit config validate <path>` when `--help` confirms the command.
2. Confirm command and option names against CLI help and current documentation first.
3. Fall back to the official JSON Schema with the repository's existing YAML tooling.
4. Report **valid** only when a supported validator succeeds; report **cannot validate** when no validator or schema evidence exists.
5. Audit with the tools already installed; a CLI install is a setup change, not an audit step.

Done when: the verdict is `valid`, `invalid: <error>`, or `cannot validate: <reason>`.

### Rule quality

| Check | Evidence to gather |
|---|---|
| Feedback vs enforcement | `profile` sets feedback volume; `request_changes_workflow` and branch protection set merge semantics. Report them separately. |
| Branch scope | `base_branches` is regex and additive to the default branch; confirm against current documentation. |
| Review cadence | Incremental, draft, auto-pause, and rate-limit defaults from current documentation. |
| Path coverage | Test `path_instructions` and `path_filters` globs against actual tracked names, including extensionless scripts, dotfiles, templates, and POSIX, Bash, and zsh dialects. |
| Test files | Language-specific test files map to the project's real test commands. |
| Guidelines | Code-guideline auto-discovery, its actual scope, explicit mappings, and UI state. A discovered instruction applies only where its scope is documented or observed. |
| Signal policy | Style-only consistency findings are suppressed; security and correctness findings stay on. |
| Duplication | Targeted rules do not repeat existing guidelines or linters. |
| Fixtures | Golden expectations stay reviewable; disposable generated noise is excluded. |
| Excludes | Default excludes are distinguished from excludes this repository added. |

Propose a preset migration only with comparative evidence from this repository.

Done when: every row has a finding or an explicit `no gap` with its evidence.

### Review completion

A green status check is a separate claim from a completed review.
Verify review events, findings, and the exact PR head SHA before reporting that a review ran.

## Setup or update

1. Show the smallest configuration diff that meets the request.
2. Validate the diff with the preferred validator, or report why validation is unavailable.
3. Change only the configuration the user requested; a wholesale template is never the answer.
4. Recheck the final diff against the user's explicit decisions.

An ordinary configuration request ends at the diff.
Posting comments, triggering paid reviews, changing branch protection or rulesets, removing Copilot, installing services or CLIs, committing, and pushing each need an explicit user request and that action's own workflow.

Done when: the diff is shown, its validation verdict is stated, and every line traces to the request.

## Red flags

Stop and investigate when:

- a green status is treated as proof that a review completed;
- a schema pass is treated as proof of path or guideline coverage;
- a discovered instruction is applied outside its documented or observed scope;
- a profile level is treated as merge enforcement without workflow and branch-rule evidence;
- a setup request grows into comments, paid reviews, branch rules, installs, or commits;
- a repository-wide preset migration appears without comparative evidence.

| Rationalization | Why it fails | Required action |
| --- | --- | --- |
| "The check is green, so CodeRabbit completed its review." | Status checks and completed-review evidence are different claims. | Verify review events, findings, and the exact PR head. |
| "The schema is valid, so coverage is adequate." | Syntax constraints do not prove path or guideline coverage. | Test representative tracked paths and report gaps. |
| "The old bot is retired, so its guidance is inactive." | Guidance can remain in files, inherited settings, or UI state. | Search sources and effective settings before removing or ignoring it. |

## Output

```markdown
## CodeRabbit <audit | setup>: <repo> [PR <n> @ <head-sha>]

- Schema: valid | invalid: <error> | cannot validate: <reason>
- Effective config source: file | inherited | UI | unknown
- Review completion (PR only): verified @ <sha> | not verified: <reason>

| # | Severity | Confidence | Check | Location | Finding | Recommendation |
|---|---|---|---|---|---|---|

### Evidence gaps
- <what was not checkable and why>

### Proposed diff (setup only)
```

Severity: blocker, high, medium, low.
Confidence: `<certain>` (cited file, doc, or PR event), `<speculative>` (checkable, unverified); drop `<don't know>`.

## Worked invocations

```text
/coderabbit audit PR 123 at the exact head and base; report findings only
/coderabbit set up CodeRabbit for this repository; propose and validate only the requested config changes
```

## Primary references

- [Configuration](https://docs.coderabbit.ai/reference/configuration)
- [Path instructions](https://docs.coderabbit.ai/configuration/path-instructions)
- [Code guidelines](https://docs.coderabbit.ai/knowledge-base/code-guidelines)
- [Auto review and rate limits](https://docs.coderabbit.ai/configuration/auto-review)
- [CLI reference](https://docs.coderabbit.ai/cli/reference)
- [Request changes workflow](https://docs.coderabbit.ai/pr-reviews/request-changes-workflow)
- [Official CLI skill distinction](https://github.com/coderabbitai/skills)

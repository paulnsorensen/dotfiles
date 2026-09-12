---
name: coderabbit
model: sonnet
effort: medium
description: >
  Audit and configure CodeRabbit settings with evidence from repository files,
  pull requests, and current primary documentation; this is not the CodeRabbit
  CLI code-review or autofix workflow. Use when the user says "configure
  CodeRabbit", "review .coderabbit.yaml", "set up CodeRabbit", or "audit
  CodeRabbit settings".
---

# CodeRabbit configuration

Audit by default. Default audit is read-only. Treat setup as a narrowly scoped configuration change.

## Scope and inputs

1. Read repository instructions. Read the relevant repository wiki when available; do not require a wiki for other repositories.
2. Identify the exact PR head and base when the request names a pull request.
3. Read current .coderabbit.yaml, repository settings, or inherited configuration evidence.
4. Read immediate build, test, and CI configuration that defines repository behavior.
5. Do not assume a main branch, repository language, path layout, or dotfiles convention.
6. Preserve explicit user decisions about scope, severity, presets, branches, and enforcement.
7. Use /briesearch when available for current documentation research; do not require it.
8. Use current primary CodeRabbit documentation and schema; do not treat defaults as timeless.

## Audit workflow

1. Separate schema validity, rule quality, and evidence of an actually completed review.
2. Check the exact PR head and base, changed paths, review status, and test status.
3. Prefer installed coderabbit config validate <path> when help confirms the command.
4. Check CLI help and current documentation before relying on command or option names.
5. Fall back to YAML and the official JSON Schema with existing repository tooling.
6. Report valid only when a supported validator succeeds.
7. Report **cannot validate** when no supported validator or schema evidence is available.
8. Do not install a CLI merely to perform an audit.
9. Inspect inherited settings and the UI when file evidence cannot establish effective behavior.
10. Distinguish profile feedback level from request_changes_workflow and branch-protection merge semantics.
11. Check base_branches regex behavior and additive default-branch behavior from current documentation.
12. Verify incremental, draft, and rate-limit defaults against current documentation.
13. Check full path coverage with actual tracked names and correct glob semantics.
14. Include extensionless scripts, dotfiles, templates, and POSIX, Bash, and zsh dialects.
15. Check language-specific test files and their corresponding project test commands.
16. Check code-guideline auto-discovery, actual scope, explicit mappings, and UI state.
17. Do not assert that every discovered instruction applies to every path.
18. Suppress style-only consistency findings, but retain security and correctness findings.
19. Check targeted rules for duplication against existing guidelines and linters.
20. Distinguish golden expectations from disposable generated noise.
21. Distinguish default excludes from excludes added by this repository.
22. Do not prescribe one review-preset migration across repositories.

## Evidence and changes

Return evidence-backed findings grouped by severity. Include each finding's location, concrete example, recommendation, confidence, test status, and explicit evidence gaps.

For setup or update requests:

- Show the smallest configuration diff that meets the request.
- Validate the proposed diff with the preferred validator or report why validation is unavailable.
- Change only user-requested configuration.
- For an ordinary configuration request, do not post comments, trigger paid reviews, change branch protection or rulesets, remove Copilot, install services or CLIs, commit, or push.
- If the user explicitly requests one of those actions, use its relevant workflow and approval requirements.
- Keep audits read-only unless the user explicitly changes the scope.
- Do not dump a wholesale configuration template.
- Recheck the final diff against the user's explicit decisions.

## Discipline

**Iron Law:** No configuration claim or edit is valid without current evidence for its scope and effective behavior.

**Red flags** — stop and investigate:

- A green status is treated as proof that a review completed.
- A schema pass is treated as proof of adequate path or guideline coverage.
- A discovered instruction is applied outside its documented or observed scope.
- A profile level is treated as merge enforcement without workflow and branch-rule evidence.
- A setup request expands into comments, paid review triggers, branch rules, installs, or commits.
- A repository-wide preset migration is proposed without comparative repository evidence.

| Rationalization | Why it fails | Required action |
| --- | --- | --- |
| "The check is green, so CodeRabbit completed its review." | Status checks and completed review evidence are different claims. | Verify review events, findings, and the exact PR head. |
| "The schema is valid, so coverage is adequate." | Syntax and schema constraints do not prove path or guideline coverage. | Test representative tracked paths and report gaps. |
| "The old bot is retired, so its guidance is inactive." | Guidance can remain in files, inherited settings, or UI state. | Search sources and effective settings before removing or ignoring it. |

## Worked invocations

Audit a pull request:

```text
/coderabbit audit PR 123 at the exact head and base; report findings only
```

Set up the current repository:

```text
/coderabbit set up CodeRabbit for this repository; propose and validate only the requested config changes
```

## Primary references

- [Configuration](https://docs.coderabbit.ai/reference/configuration)
- [Path instructions](https://docs.coderabbit.ai/configuration/path-instructions)
- [Code guidelines](https://docs.coderabbit.ai/knowledge-base/code-guidelines)
- [CLI reference](https://docs.coderabbit.ai/cli/reference)
- [Request changes workflow](https://docs.coderabbit.ai/pr-reviews/request-changes-workflow)
- [Official CLI skill distinction](https://github.com/coderabbitai/skills)

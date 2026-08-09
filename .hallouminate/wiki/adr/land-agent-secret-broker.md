# ADRs — land the agent-secret broker (PR #616)

Rationale record for the land-agent-secret-broker spec (durable spec:
~/.local/share/cheese/paulnsorensen-dotfiles/specs/land-agent-secret-broker.md;
research slugs bws-token-storage-fork and harness-bws-runtime-injection under
the same corpus). Session date: 2026-08-08. Related:
[[architecture/agent-secret-isolation-001]] (lands with the PR),
[[architecture/mcp-secret-handling]].

## ADRs

### ADR-001: Land the existing broker rather than re-scope it or switch to bws-run wrappers  [status: accepted]

- **Context:** The user's requirement is that a same-user coding agent cannot read secret values ("isolation", not "hygiene"). Research showed: `pass`/gpg on headless Linux degrades to same-user-readable state (agent cache TTL or loopback passphrase file); the macOS `security` CLI cannot enforce user presence (no ACL/partition-list mechanism gates a live check — only a compiled Data-Protection-Keychain binary can); `bws run` wrappers leave the machine token invocable by any same-user process. A root-ownership boundary is the only mechanism that meets the bar on both platforms, and PR #616 already implements it.
- **Decision:** Land PR #616 with a fix list (rebase, #598 rename port, verification sweep, deny-block fold) rather than re-scoping the broker or replacing it with `bws run` command wrappers.
- **Rejected:** `bws run --` wrapper redesign (hygiene, not isolation — recorded in .cheese/.out-of-scope/land-agent-secret-broker-001.md); re-scoping the broker down before landing (grill found the surface justified: 100% stdlib, real behavior tests, clean rebase).

### ADR-002: Keep the write-nonce machinery although the chosen bar doesn't require it  [status: accepted]

- **Context:** The user chose bar 2 (root-boundary isolation); the shipped broker also implements bar 3 (one-shot 60s operator nonces on write tools). The grill found the nonce machinery cleanly separable (~20% of the daemon behind a single read/write gate at scripts/agent-secret-broker.py:588-591), so stripping was a real option.
- **Decision:** Keep as shipped. Nonces fire only on todoist/github write tools (context7/tavily are read-only), so day-to-day friction is near zero, and deleting working, tested security code to match a bar exactly is its own risk. Revisit if friction materializes.
- **Rejected:** Stripping to bar 2 (mechanical but unnecessary churn); policy-level relaxation (moving write tools to the pass-through list — subverts the policy vocabulary).

### ADR-003: Close PR #598; port only its Keychain service rename  [status: accepted]

- **Context:** #598 (green, unreviewed) renames the macOS Keychain service to `bws_access_token` and exports the token into every interactive zsh. #616 still uses the old service name (branch vault.sh:139-140) — a real semantic conflict — and its scrub model makes the zsh export a regression, not a fix.
- **Decision:** Port the `bws_access_token` rename into #616 (curd C2); close #598 with a supersession comment explaining the split verdict on its two halves.
- **Rejected:** Landing #598 first (churn: immediate rebase + deletion of its zsh-export half); keeping the old `BWS_ACCESS_TOKEN` service name (perpetuates the name collision between env var and Keychain service that #598 existed to fix).

### ADR-004: Harness deny rules are a friction layer, never the boundary  [status: accepted]

- **Context:** An uncommitted claude.yaml `permissions.deny` block (bws, security) predated this session. Vendor docs for both Claude Code and Codex state their command/path rules are bypassable via `sh -c`-class indirection, and Codex permission profiles explicitly do not govern MCP subprocesses.
- **Decision:** Fold the deny block into the landing (curd C3) documented as friction-not-boundary, layered on the root boundary. A codex `.rules` mirror is follow-up F004.
- **Rejected:** Dropping the block as redundant (cheap friction still raises the bypass cost); treating deny rules as the primary control (documented-bypassable — the failure mode this whole spec exists to close).

### ADR-005: Remove the github MCP consumer from the branch  [status: accepted]

- **Context:** The broker commit (725b4fd5) introduced a github consumer, but main never had a github MCP (no `github` entry in main's `claude.yaml`), and `gh` CLI already covers GitHub operations. Shipping the consumer would add a GitHub App requirement as net-new scope beyond what the broker needed to land.
- **Decision:** Operator-directed removal (bce694c8) of the github consumer: `install_github_runtime`, `GITHUB_APP_*` settings, and the github entries in `claude.yaml`/`codex.yaml` and downstream registries/profiles/tests.
- **Rejected:** Keeping the github consumer and its GitHub App provisioning (scope the landing didn't need and main never carried).

---
name: routine-env
model: sonnet
effort: medium
allowed-tools: Read, Write, Edit, Bash(claude:*), Bash(npx:*), Bash(jq:*), Bash(yq:*), mcp__tilth__*
description: >
  Render or apply a "routine env" — a named bundle of Claude Code plugins + MCP
  servers + skill packs defined in `envs/<name>.yaml` — into a setup-script body
  for Claude Cloud (Claude Code on the web), or apply it to the local machine.
  Use when the user says "set up a routine env", "provision my Claude Cloud
  environment", "install my cheese env", "render the setup script for <env>",
  "update my env", "scaffold a new env", or invokes "/routine-env". Do NOT use
  for cloud cron/scheduled agents that open PRs (that is `routine-scaffold`) or
  for a personal CLAUDE.md preferences overlay in a contributed repo (that is
  `claude-local`) — routine-env is about plugin/MCP/skill provisioning only.
---

# routine-env

Turns an `envs/<name>.yaml` bundle definition into the commands that actually
install it — either as a setup-script body to paste into the Claude Cloud UI,
or run directly on the local machine.

## What a routine env is

A **routine env** = a named, versioned bundle of:

- **marketplaces** — `claude plugin marketplace add <ref>` sources
- **plugins** — `claude plugin install <id>` targets (`<plugin>@<marketplace-id>`)
- **mcp** — npx-launched MCP servers (not plugins)
- **skills** — skill packs installed via the `npx skills@latest` CLI

Definitions live in `envs/<name>.yaml` at the repo root (see `envs/README.md`
for the full schema and field-by-field rationale). This skill is the only
consumer of `envs/` — the directory is standalone data, not wired into `ap`,
`profiles/base`, the `agents/` registries, or `dots sync`.

## The Claude Cloud reality

"Claude Cloud" here means **Claude Code on the web** (`claude.ai/code`), a
different product from Managed Agents (`ant beta:environments`). Ground facts
from `.cheese/research/routine-env-provisioning/routine-env-provisioning.md`
(addendum, A1/A2/A5):

- The environment's setup script is **UI-configured plain bash** — typed into
  the Claude Cloud environment dialog's "setup script" field. It is **not** a
  repo-committed file, and `<certain>` there is **no CLI/API to push it from
  git**. This skill cannot write directly to that dialog — it can only render
  the bash body for the user to paste in.
- The setup script runs **once per build cache-miss** (first run, or after an
  invalidating change) and then persists into every session reusing that
  cached container — it is not re-run per session.
- **A3 caveat — the setup-script install path is unverified.** Whether
  `claude`/`node`/`npx` are even available inside the setup-script shell, and
  whether a plugin or skill installed there survives into the booted session,
  is graded `<don't know>` in the research (A3): every official setup-script
  example is plain OS commands (`apt install`, `docker compose`); none invoke
  `claude`, `npx`, or `node`. Spike this empirically on a real Claude Cloud
  environment before relying on the rendered setup script for plugins/skills.
- **The confirmed (`<certain>`) path for plugins/skills-only envs is
  git-native, not the setup script.** A repo's committed
  `.claude/settings.json` (`enabledPlugins`/`extraKnownMarketplaces`)
  auto-installs at cloud session start with zero setup-script involvement,
  and `.claude/skills/` loads with the clone — no install step, no A3
  uncertainty. When an env only needs plugins/skills (no OS packages, no
  services), committing to `.claude/` is the confirmed default, and
  `render`ing a setup-script body is the fallback for what that path can't
  cover (OS packages, background services) — not the default over a
  confirmed path. Mention the `.claude/` alternative to the user before
  reaching for `render` on a plugins/skills-only env.

## Modes

### `render <env>`

1. Read `envs/<env>.yaml`.
2. Emit **one** idempotent bash setup-script body, in this order:
   - `claude plugin marketplace add <ref>` for each `marketplaces[]` entry
   - `claude plugin install <id>` for each `plugins[]` entry
   - `claude mcp add <name> -- npx -y <package>` for each `mcp[]` entry
     (e.g. `claude mcp add tilth -- npx -y @paulnsorensen/tilth-nightly`)
   - `npx skills@latest add <pack> <args>` for each `skills[]` entry
3. Every command must be safe to re-run (idempotent) — rely on each CLI's own
   already-installed/already-added no-op behavior; do not add custom existence
   checks that duplicate what the CLI already handles.
4. Print the rendered body as a single fenced bash block the user can paste
   verbatim into the Claude Cloud environment dialog's setup-script field.

### `apply-local <env>`

Run the same rendered commands directly on the current machine via `Bash`, in
the same order as `render`. Report each command's outcome.

### `update <env>`

Bump plugin/skill versions or ids in `envs/<env>.yaml` (e.g. after confirming
a new marketplace id or skill pack revision), then re-run `render <env>` so
the user has the refreshed setup-script body to re-paste.

### `new <name>`

Scaffold a fresh `envs/<name>.yaml` from the locked schema in `envs/README.md`
(`name`, `description`, `marketplaces`, `plugins`, `mcp`, `skills`), with the
same inline confirm-comment on every `plugins[].id`. Leave placeholder values
for the user to fill in — do not fabricate marketplace ids or skill packs.

## Verification

- Confirm every `plugins[].id` marketplace segment against `claude plugin
  marketplace list` before treating it as final — a marketplace's actual
  `.name` in its `marketplace.json` is not assumed by `envs/*.yaml`.
- Reuse plugin coordinates from `agents/plugins/registry.yaml` (the
  cross-harness plugin registry) — that file is the source of truth for which
  plugin lives at which marketplace; do not invent new coordinates in
  `envs/*.yaml`.

## What it never does

- **Not cloud cron/scheduled agents.** A routine env provisions plugins/MCP/
  skills for a session to boot with; it never authors a recurring watcher that
  opens PRs — that is `routine-scaffold`.
- **Not a CLAUDE.md preferences overlay.** It does not distill or write a
  `CLAUDE.local.md` — that is `claude-local`.
- **Does not wire into `ap`, `profiles/base`, the `agents/` registries, or
  `dots sync`.** `envs/` is standalone data consumed only by this skill.
- **Does not push the rendered setup script into the Claude Cloud UI
  programmatically** — no such CLI/API exists (see "The Claude Cloud reality"
  above); the user pastes the rendered body in manually.
- **Does not fabricate marketplace ids or skill packs** — every id traces to
  `agents/plugins/registry.yaml` or an explicit user-confirmed source, with the
  `claude plugin marketplace list` confirmation step called out above.

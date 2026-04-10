---
name: explore
description: >
  Code exploration orchestrator. Takes a free-form query and dispatches four parallel
  leaf sub-agents (graph, tilth, tokei, LSP) for structural, token-budgeted, statistical,
  and type-aware perspectives. Synthesizes into a structured XML artifact with codebase
  map, business context per module, and change callstack. Use when the user says "explore,"
  "how does X work," "explain this codebase," "map the architecture," "what needs to
  change for X," "where is Y implemented," or invokes /explore. Do NOT use for
  implementation (fromage-cook), dead-code audits (ghostbuster), PR review (age),
  or onboarding narratives (onboard).
model: opus
allowed-tools: [Bash(git status:*), Bash(git rev-parse:*), Bash(git ls-files:*), Bash(which:*), Bash(jq:*), Read, Glob, Grep, Agent, Write]
---

# explore

Free-form code exploration via four specialized sub-agents. One query in, one XML artifact out.

> **Architecture note**: This is a SKILL (not an agent) so the four sub-agents are first-level agents, avoiding nested-agent depth issues.

## Sub-Agents

| Agent | Specialty | Shines at |
|-------|-----------|-----------|
| `explore-graph` | code-review-graph MCP plugin | Multi-hop call chains, impact radius, flows, communities, architecture overview |
| `explore-tilth` | Tree-sitter smart reader | Token-budgeted file/symbol reads, callers, deps, structural map |
| `explore-tokei` | Language/file statistics | Size, language mix, mass concentration, largest files |
| `explore-lsp` | Language server navigation | Type-resolved definitions, references, hover, call hierarchy |

Tool division rule-of-thumb: **LSP for single-hop precision, graph for multi-hop chains, tilth for budget-capped reads, tokei for scale.**

## Modes

### Understand mode (default)

"How does X work?" / "What is this codebase?" / "Where is Y implemented?"

Produces: `<summary>`, `<stats>`, `<map>`, `<business>`, optionally `<flow>`.

### Change-plan mode

"What needs to change to add feature X?" / "How would I refactor Y?"

Produces everything from Understand mode **plus** `<change-plan>` with ordered steps and affected callers.

Detect change-plan mode by verb cues in the query: *add, remove, change, refactor, extend, support, introduce, replace*.

## Protocol

### Step 1: Parse the query

Extract from `$ARGUMENTS`:

- The free-form **question** (required)
- Optional **scope** flag (`--scope <dir>`), defaults to `.`
- Optional **budget** flag (`--budget <N>`), defaults to 4000 tokens per sub-agent
- Optional **out** flag (`--out <path>`), defaults to `.claude/exploration/<slug>.xml`
- Detect **mode**: change-plan vs understand (verb cues above)

If the question is empty, ask the user for one. Don't guess.

### Step 2: Freshness probe (cheap, parallel)

Run these three checks in parallel before dispatching sub-agents:

1. `git status --porcelain` — is the tree dirty?
2. `git rev-parse HEAD` — what revision are we at?
3. `which tilth tokei` — confirm CLIs are installed

If tilth or tokei are missing, report it and exit — don't fall back to grep. If the tree is dirty, note it in `<sources>` so the graph's freshness is clear.

### Step 3: Dispatch sub-agents in parallel

Launch ALL FOUR sub-agents in a **single message** (one message, four `Agent` tool calls). Each sub-agent receives the same base context plus a tool-specific framing:

```
Agent(subagent_type="explore-graph", prompt="Query: <question>\nScope: <scope>\nMode: <mode>\nBudget hint: <budget>\n\nAnswer using code-review-graph. Run build_or_update_graph_tool once if the tree was modified. Return structured JSON per your agent protocol.")

Agent(subagent_type="explore-tilth", prompt="Query: <question>\nScope: <scope>\nMode: <mode>\nBudget: <budget>\n\nAnswer using tilth. Use --map for orientation, --callers/--deps for relationship queries, --expand for symbol reads. Always --json --budget. Return structured JSON per your agent protocol.")

Agent(subagent_type="explore-tokei", prompt="Query: <question>\nScope: <scope>\n\nRun tokei on the scope and return language breakdown, largest files, and mass concentration. Use --files --output json. Return structured JSON per your agent protocol.")

Agent(subagent_type="explore-lsp", prompt="Query: <question>\nScope: <scope>\nMode: <mode>\n\nAnswer type-aware questions using LSP. If the query is clearly multi-hop or architectural, defer to explore-graph (return confidence ~30 with a defer note). Return structured JSON per your agent protocol.")
```

Each sub-agent returns **structured JSON only** — no narrative. That keeps parent context clean.

### Step 4: Synthesize into XML artifact

Merge the four JSON payloads into one XML document per the schema below. Rules:

- **Do not duplicate findings** — if both graph and LSP surface the same caller, list it once. Use a space-separated `sources="graph lsp"` attribute on the enclosing section.
- **Prefer the highest-confidence source** when sub-agents disagree on a fact, but record the disagreement in `<notes severity="warn">`.
- **Never entirely omit optional sections.** Emit a sentinel instead: `<change-path omitted="true" reason="query is not change-oriented"/>`. Parser-stable is more important than compact.
- **Wrap any code samples in CDATA.** Never embed raw `<`, `>`, or `&` in text nodes.
- **Use attributes for scalars** (paths, line numbers, counts, confidence). Use child elements for multi-line prose.
- **No markdown inside XML** — plain prose only in text nodes. No code fences, no `**bold**`, no bullet characters.
- **Confidence is always an integer 0–100.** Never a float.
- **Sub-agent ↔ section boundary**: `<structure>` is tilth+tokei territory, `<context>` is graph territory, `<change-path>` blends LSP (ground truth) + graph (inferred edges). Label accordingly on each section.

### Step 5: Write and display

1. Write the XML to `--out` path (create parent dir if needed).
2. Print the artifact path + a ≤10-line plain-text summary to the main context. Do NOT dump the full XML into the main context — that's what the file is for. The caller can `Read` it when needed.

## XML Schema

```xml
<?xml version="1.0" encoding="UTF-8"?>
<exploration
  schema-version="1.0"
  query="how does authentication work?"
  generated-at="2026-04-08T12:34:56Z"
  scope="."
  mode="understand"
  revision="abc1234"
  dirty="false">

  <!-- Provenance — one entry per sub-agent that actually ran -->
  <sources>
    <source id="graph" agent="explore-graph" confidence="84"
            sequence="build_or_update_graph_tool,get_architecture_overview_tool,get_review_context_tool,get_impact_radius_tool"/>
    <source id="tilth" agent="explore-tilth" confidence="78"
            sequence="tilth --map --json,tilth UserSession --callers --json"/>
    <source id="tokei" agent="explore-tokei" confidence="95"
            sequence="tokei --files --output json"/>
    <source id="lsp" agent="explore-lsp" confidence="88"
            sequence="workspaceSymbol,goToDefinition,findReferences,callHierarchy"/>
  </sources>

  <summary confidence="82"><![CDATA[
    Authentication flows from src/adapters/http/auth_handler.rs → src/domains/auth/session.rs →
    src/domains/auth/token.rs. Sessions live 24h; refresh extends via TokenStore::issue.
  ]]></summary>

  <!-- Structural facts: tilth + tokei territory -->
  <structure sources="tilth tokei">
    <stats>
      <total files="312" code="48210" comments="8041" blanks="6120"/>
      <lang name="Rust" files="180" code="32100" pct="66.6"/>
      <lang name="Shell" files="45" code="6200" pct="12.9"/>
    </stats>
    <module name="auth" path="src/domains/auth" role="domain" code="1104">
      <file path="src/domains/auth/index.rs" code="42" fingerprint="sha1:a3f9e2"/>
      <file path="src/domains/auth/session.rs" code="342" fingerprint="sha1:b81c44">
        <symbol name="UserSession" kind="struct" exported="true" line="12"/>
        <symbol name="refresh" kind="method" parent="UserSession" exported="true" line="42"/>
      </file>
      <file path="src/domains/auth/token.rs" code="218" fingerprint="sha1:cc2217">
        <symbol name="TokenStore" kind="trait" exported="true" line="8"/>
        <symbol name="TokenStore::issue" kind="method" exported="true" line="55"/>
      </file>
    </module>
    <module name="http" path="src/adapters/http" role="adapter" code="842">
      <file path="src/adapters/http/auth_handler.rs" code="201" fingerprint="sha1:d41f09">
        <symbol name="login" kind="fn" exported="true" line="34"/>
      </file>
    </module>
  </structure>

  <!-- Semantic / business context: graph territory -->
  <context sources="graph">
    <module name="auth">
      <purpose><![CDATA[
        Owns user session lifecycle, token refresh, and credential validation.
        Business rule: sessions expire after 24h unless refreshed via TokenStore::issue.
      ]]></purpose>
      <dependencies>
        <dep module="http" reason="inbound credentials arrive via login handler"/>
        <dep module="common" reason="uses shared error types"/>
      </dependencies>
    </module>
    <module name="http">
      <purpose><![CDATA[
        HTTP transport layer. Translates REST requests into domain calls; enforces
        rate limits on the login endpoint.
      ]]></purpose>
      <dependencies>
        <dep module="auth" reason="delegates credential verification"/>
      </dependencies>
    </module>
  </context>

  <!-- Optional: a named end-to-end flow. Emit sentinel if not applicable. -->
  <flow name="login" sources="graph lsp" confidence="88">
    <step order="1" file="src/adapters/http/auth_handler.rs" symbol="login" line="34">
      <description>Receives POST /login, parses credentials, enforces rate limit</description>
    </step>
    <step order="2" file="src/domains/auth/session.rs" symbol="UserSession::create" line="18">
      <description>Validates credentials against store, creates session</description>
    </step>
    <step order="3" file="src/domains/auth/token.rs" symbol="TokenStore::issue" line="55">
      <description>Issues JWT with 24h expiry; persists refresh token</description>
    </step>
  </flow>

  <!-- Optional: change path for a planned feature. LSP-confirmed edges carry ground truth. -->
  <change-path feature="add OAuth2 support" sources="lsp graph" confidence="71">
    <rationale><![CDATA[
      Adding an OAuth2 provider requires a new adapter, a domain extension to accept
      federated principals, and handler routing for the callback.
    ]]></rationale>
    <step order="1" action="add" path="src/adapters/oauth2/provider.rs">
      <rationale>New inbound adapter for OAuth2 callback</rationale>
    </step>
    <step order="2" action="modify" path="src/domains/auth/session.rs" symbol="UserSession::create">
      <rationale>Accept an optional OAuth2 principal in addition to credentials</rationale>
    </step>
    <step order="3" action="modify" path="src/domains/auth/token.rs" symbol="TokenStore::issue">
      <rationale>Claims must include an oauth2 issuer marker for federated tokens</rationale>
    </step>
    <edges>
      <edge from="src/adapters/http/auth_handler.rs:login"
            to="src/domains/auth/session.rs:UserSession::create"
            kind="calls" lsp-confirmed="true"/>
      <edge from="src/domains/auth/session.rs:UserSession::create"
            to="src/domains/auth/token.rs:TokenStore::issue"
            kind="calls" lsp-confirmed="true"/>
      <edge from="src/adapters/oauth2/provider.rs"
            to="src/domains/auth/session.rs:UserSession::create"
            kind="calls" lsp-confirmed="false"/>
    </edges>
  </change-path>

  <notes>
    <note severity="info">No OAuth2 adapter exists — green-field slice needed under src/adapters/</note>
    <note severity="warn">UserSession::refresh has 14 call sites — non-trivial ripple if its signature changes</note>
  </notes>
</exploration>
```

### Sentinels for absent optional sections

Never drop a tag entirely. Emit a sentinel instead so downstream parsers have a stable tree:

```xml
<flow omitted="true" reason="query did not resolve a named flow"/>
<change-path omitted="true" reason="query is not change-oriented"/>
```

### Schema rules

- **Attributes for scalars** (path, line, file, count, confidence, fingerprint, order, action). **Child elements for prose** (description, purpose, rationale).
- **Every `<source>` in `<sources>` must reference an agent that actually ran.** If a sub-agent failed, include it with `confidence="0"` and a matching `<note severity="warn">` entry.
- **Section-level provenance**: every section (`<structure>`, `<context>`, `<flow>`, `<change-path>`) carries `sources="..."` (space-separated agent ids) matching IDs from `<sources>`.
- **Optional sections emit sentinels** — `<flow omitted="true"/>`, `<change-path omitted="true"/>`. Never silently drop.
- **`fingerprint` on `<file>`** = SHA-1 of the file's content at exploration time. Enables reviewers to diff two runs and see which files changed underneath the artifact.
- **CDATA for multi-line prose** and anything containing `<`, `>`, or `&`.
- **Confidence is an integer 0–100**, never a float.
- **No markdown** — no `**bold**`, no code fences, no bullet characters inside text nodes.
- **Deterministic order**: list children sorted by path then line for diff-friendliness. Attribute order: `name`, `kind`, `path`/`file`, `line`, `confidence`, `sources`, then everything else.
- **`schema-version`** on the root — bump major on breaking changes, minor on additive fields.

## Rules

- **Always parallelize the four sub-agents** in a single message.
- **Never dump sub-agent raw JSON into the main context** — parse and synthesize into XML, then write to file.
- **If fewer than 2 sub-agents succeed**, report confidence=low and recommend re-running; do not fabricate findings.
- **Respect the tool division** — don't ask explore-graph to do single-hop navigation, don't ask explore-lsp to do architecture overview.
- **When agents disagree** on a fact, record both in `<notes severity="warn">` and use the higher-confidence value in the main body.
- **Never modify code** — exploration is read-only. Write is allowed only for the XML artifact.
- Keep the main-context summary ≤10 lines. The XML file is the full artifact.

## Confidence rollup

The orchestrator's top-level `<summary confidence="...">` is a weighted average:

- explore-graph: 0.30 (structural authority)
- explore-lsp: 0.25 (type-resolved ground truth)
- explore-tilth: 0.25 (fast structural sanity check)
- explore-tokei: 0.20 (scale sanity check)

Sub-agents that failed (confidence 0) contribute 0 and their weight is redistributed.

## What This Skill Never Does

- Review code quality or score issues (use /age)
- Plan implementation steps or write code (use /fromage)
- Produce onboarding narratives or tutorials (use /onboard)
- Map architecture for a specific change task (use /fromage-culture)
- Estimate token budgets for implementation atoms (use culture-tokei)
- Modify any source files — Write is for the XML artifact only

## Gotchas

- Sub-agents added mid-session aren't discoverable until Claude Code restarts.
  If Agent() calls fail with "agent type not found", the agents exist on disk
  but the session's agent list was snapshotted at boot.
- code-review-graph only indexes JavaScript and Python. Shell-dominated repos
  will get confidence ~25 from explore-graph. Note this honestly in the output
  rather than omitting the agent.
- explore-lsp legitimately defers on architectural queries (confidence ~30).
  This is correct behavior, not a failure — don't retry or substitute.
- tokei JSON post-processing via jq: use `select(.key == "Total" | not)` instead
  of `select(.key != "Total")` — shell history expansion can mangle `!=`.
- If fewer than 2 sub-agents succeed, report confidence=low and recommend
  re-running. Do not synthesize from a single source.

## Output contract

Every run MUST produce:

1. An XML artifact at `--out` (or default path), valid against the schema above.
2. A ≤10-line plain-text summary to the main context, including: artifact path, query, top 3 findings, top 3 risks/unknowns, overall confidence.

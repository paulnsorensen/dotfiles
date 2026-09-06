# Explorer artifact contract

Status: proposed in `fix/harness-explorer-contract`; not merged or deployed.

The user accepts source-read-only explorers with optional evidence artifacts.
Parents retain decisions, dialogue, and canonical reports.
Explorers return short evidence digests.
They may write their own `.cheese/explore/` overflow artifact only when the caller permits it.
An explicit read-only or no-write request disables artifact writes.

A reachable `tilth_write` tool makes the renderer classify Explorer as writable.[^1]
That classification is correct for artifact-capable agents.
The path restriction is an instruction contract, not an operating-system boundary.
Native mutation tools remain denied.
OMP has no dedicated artifact writer, but its Bash tool can mutate files.
Its no-write restriction therefore also needs instruction enforcement.

The tracked easy-cheese resolver accepts prompt-only read-only fallback only for general workers.[^2]
The companion resolver PR extends that exception to eligible specialist candidates.[^3]
It retains `permission_enforcement: prompt-only` and `degraded: true` for no-write requests without tool enforcement.
It does not relax required write capability or stronger isolation.
Caller files can retain their read-only requests.

The rejected alternative removes every write tool from Explorer.
The user accepts optional evidence artifacts, so explicit caller constraints preserve more useful behavior.
Do not report cross-repository alignment as complete before the resolver change lands.

[^1]: Dotfiles `agent-profile/agent_profile/shared.py:57-108` and `agent-profile/agent_profile/renderers/codex.py:140-152`.
[^2]: Easy-cheese `skills/cheese/references/agent-resolution.md:11-20,61`; read-only callers include `skills/mold/references/context-budget.md:7` and `skills/culture/SKILL.md:30`.

[^3]: <https://github.com/paulnsorensen/easy-cheese/pull/627>; publication commit `e2310a7a2444fa7ad23c55badedbfbdd8ad06049`.

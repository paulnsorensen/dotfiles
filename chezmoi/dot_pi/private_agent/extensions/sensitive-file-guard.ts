// Pi-native sensitive-file guard — ports agents/lib/sensitive-file-guard.js's
// detection rules (the shared Claude/Codex PreToolUse hook) to Pi's
// tool_call extension API. Pi has no PreToolUse hook mechanism, so this is a
// self-contained TS extension rather than a require() of the Node module
// (matches the rtk.ts/cheese-flair.ts vendoring pattern: no cross-tree
// requires of chezmoi-deployed sources).
//
// Covers Pi's built-in read/write/edit/bash tools and the direct-mode tilth
// MCP tools (tilth_read, tilth_write — toolPrefix "none" in mcp.json, so
// they appear unprefixed). Blocks by returning { block: true, reason } from
// the tool_call handler.
//
// Enforced by default (opt-out):
//   CLAUDE_SENSITIVE_GUARD=0|false|off|no   → disable entirely
// Allow-list escape hatch (substring match against the path):
//   CLAUDE_SENSITIVE_GUARD_ALLOW=/abs/ok.env,fixtures/  (comma-separated)

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

// Non-secret .env companions — checked-in templates, never hold real values.
const SAFE_ENV = /\.(example|sample|template|dist|defaults)$/i

// Credential stores keyed by exact basename.
const SENSITIVE_BASENAMES = new Set([
  ".netrc", "_netrc", ".pgpass", ".npmrc", ".pypirc",
  ".git-credentials", ".htpasswd", "kubeconfig",
  "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
])

// Private-key / keystore file extensions.
const SENSITIVE_EXT = /\.(pem|key|p12|pfx|keystore|jks|ppk)$/i

// Secret bundles by basename shape.
const SENSITIVE_NAME = [
  /^secrets?\.(ya?ml|json|toml|env)$/i, // secrets.yaml, secret.json
  /\.secret$/i,
]

function isDisabled(): boolean {
  const v = (process.env.CLAUDE_SENSITIVE_GUARD || "").trim().toLowerCase()
  return v === "0" || v === "false" || v === "off" || v === "no"
}

function allowList(): string[] {
  return (process.env.CLAUDE_SENSITIVE_GUARD_ALLOW || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
}

function isEnvFile(base: string): boolean {
  if (base === ".env") return true
  if (!base.startsWith(".env.")) return false
  return !SAFE_ENV.test(base)
}

// True when the basename names secret-bearing material.
function sensitiveBasename(base: string): boolean {
  if (!base) return false
  if (isEnvFile(base)) return true
  if (SENSITIVE_BASENAMES.has(base)) return true
  if (SENSITIVE_EXT.test(base)) return true
  return SENSITIVE_NAME.some((re) => re.test(base))
}

// True when the path sits inside a private credential directory.
function sensitiveDir(p: string): boolean {
  if (/(^|\/)\.aws\/credentials$/.test(p)) return true
  if (/(^|\/)\.gnupg\//.test(p)) return true
  // .ssh private material — allow the public/known/config companions.
  if (/(^|\/)\.ssh\//.test(p)) {
    const base = p.slice(p.lastIndexOf("/") + 1)
    if (base.endsWith(".pub")) return false
    if (base === "known_hosts" || base === "config" || base === "authorized_keys") return false
    return true
  }
  return false
}

export function isSensitive(rawPath: unknown): boolean {
  if (!rawPath) return false
  const p = String(rawPath).trim()
  if (!p) return false
  if (allowList().some((a) => p.includes(a))) return false
  const base = p.slice(p.lastIndexOf("/") + 1)
  return sensitiveBasename(base) || sensitiveDir(p)
}

// Pull candidate paths out of a Bash command line — same tokenizer as the
// shared Node guard (split on whitespace/`=`/attach metacharacters/command
// separators, then strip residual quote noise).
function bashTokens(command: string): string[] {
  return String(command)
    .split(/[\s=<>|&@;()$`]+/)
    .map((t) => t.replace(/^['"]|['"]$/g, ""))
    .filter(Boolean)
}

export function extractTargets(toolName: string, input: Record<string, unknown> | undefined): string[] {
  if (!input) return []
  if (toolName === "bash") return bashTokens(String(input.command ?? ""))
  if (toolName === "read" || toolName === "write" || toolName === "edit") {
    return typeof input.path === "string" ? [input.path] : []
  }
  if (toolName === "tilth_read") {
    const paths = input.paths
    return Array.isArray(paths) ? paths.filter((p): p is string => typeof p === "string") : []
  }
  if (toolName === "tilth_write") {
    const edits = input.edits
    if (!Array.isArray(edits)) return []
    return edits
      .map((e) => (e && typeof e === "object" ? (e as Record<string, unknown>).path : undefined))
      .filter((p): p is string => typeof p === "string")
  }
  return []
}

export function blockedTargets(toolName: string, input: Record<string, unknown> | undefined): string[] {
  return extractTargets(toolName, input).filter(isSensitive)
}

export function denyReason(toolName: string, hit: string[]): string {
  return `Blocked: ${toolName} touches sensitive file(s): ${hit.join(", ")}

These hold secrets (.env values, private keys, credentials) and must not be
read into the agent context or modified by an automated tool.

- Need a real value? Pull it yourself and paste only what's required.
- Reading a checked-in template? Use the .env.example/.sample variant.
- Genuinely need access this session? export CLAUDE_SENSITIVE_GUARD=0
- Allow specific paths only: export CLAUDE_SENSITIVE_GUARD_ALLOW=/abs/path,substr`
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", (event) => {
    if (isDisabled()) return
    const hit = blockedTargets(event.toolName, event.input as Record<string, unknown> | undefined)
    if (hit.length === 0) return
    return { block: true, reason: denyReason(event.toolName, hit) }
  })
}

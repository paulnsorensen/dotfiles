// Sliced Bread audit command. It sends a structured user prompt whose standalone
// `workflowz` routing token activates OMP's native task-graph mode.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

type Options = {
  scope: string
  minSeverity: "blocker" | "high" | "medium" | "low"
  dryRun: boolean
  maxIssues: number
  workers: number
}

const SEVERITIES: Record<Options["minSeverity"], true> = { blocker: true, high: true, medium: true, low: true }
const DEFAULT_OPTIONS: Options = {
  scope: ".",
  minSeverity: "medium",
  dryRun: false,
  maxIssues: 25,
  workers: 4,
}

function usage(reason?: string): string {
  const prefix = reason ? `${reason}\n\n` : ""
  return `${prefix}Usage: /sliced-bread-audit [scope] [--dry-run] [--min-severity=blocker|high|medium|low] [--max-issues=1..100] [--workers=1..16]`
}

function isSeverity(value: string): value is Options["minSeverity"] {
  return Object.hasOwn(SEVERITIES, value)
}

function parseOptions(raw: string): Options | string {
  const options = { ...DEFAULT_OPTIONS }
  const positionals: string[] = []

  for (const token of raw.trim().split(/\s+/).filter(Boolean)) {
    if (token === "--dry-run") {
      options.dryRun = true
    } else if (token.startsWith("--min-severity=")) {
      const severity = token.slice("--min-severity=".length)
      if (!isSeverity(severity)) return usage(`Invalid min severity: ${severity}`)
      options.minSeverity = severity
    } else if (token.startsWith("--max-issues=")) {
      const value = Number(token.slice("--max-issues=".length))
      if (!Number.isInteger(value) || value < 1 || value > 100) return usage("max-issues must be an integer from 1 to 100")
      options.maxIssues = value
    } else if (token.startsWith("--workers=")) {
      const value = Number(token.slice("--workers=".length))
      if (!Number.isInteger(value) || value < 1 || value > 16) return usage("workers must be an integer from 1 to 16")
      options.workers = value
    } else if (token.startsWith("-")) {
      return usage(`Unknown option: ${token}`)
    } else {
      positionals.push(token)
    }
  }

  if (positionals.length > 1) return usage("Pass one scope path only")
  if (positionals[0]) options.scope = positionals[0]
  return options
}

export default function (pi: ExtensionAPI) {
  pi.registerCommand("sliced-bread-audit", {
    description: "Run a severity-ranked Sliced Bread audit through OMP's native workflow runner",
    handler: async (args, ctx) => {
      const options = parseOptions(String(args ?? ""))
      if (typeof options === "string") {
        ctx.ui.notify(options, "error")
        return
      }

      await pi.sendUserMessage(`workflowz

Run a Sliced Bread architecture and code-quality audit.

Scope: ${options.scope}
Severity floor: ${options.minSeverity}
Maximum issues: ${options.maxIssues}
Evaluation workers: ${options.workers}
Dry run: ${options.dryRun}

Build this as a deterministic task graph, not as a single review. First map the scope into vertical slices; merge micro-directories with fewer than three files into their parent. In parallel, prepare GitHub deduplication context and assign evaluator workers to slices plus one cross-slice dependency/API pass. Run no more than ${options.workers} evaluator tasks concurrently, including the cross-slice pass. Every evaluator returns structured candidate findings with dimension, severity, file, line, quoted evidence, behavioral impact, and one-line fix direction.

After all evaluators finish, run a citation-verification task that rejects uncited, below-floor, or malformed findings. Then run an independent adversarial-refuter task against every blocker and high finding; retain only verified high-severity findings. Dedupe surviving findings by file, dimension, and ten-line bucket, then against existing audit issues.

When dry run is false, file at most ${options.maxIssues} fresh confirmed findings as GitHub issues using labels sliced-bread-audit and sev:<severity>. When dry run is true, do not mutate GitHub; report the proposed issues instead. Never modify production code during this audit.

Return a severity-ranked report with findings, refuted candidates, clean dimensions, and every issue URL or proposed issue.`)
      ctx.ui.notify("Sliced Bread audit workflow queued.", "info")
    },
  })
}

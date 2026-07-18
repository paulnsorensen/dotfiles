// NIH (Not-Invented-Here) scanner audit command. It sends a structured user
// prompt whose standalone `workflowz` routing token activates OMP's native
// task-graph mode. Report only — never files issues or mutates code.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

type Options = {
  scope: string
  minUsage: number
  maxCandidates: number
  workers: number
  languages?: string[]
}

const DEFAULT_OPTIONS: Options = {
  scope: ".",
  minUsage: 0,
  maxCandidates: 25,
  workers: 4,
}

function usage(reason?: string): string {
  const prefix = reason ? `${reason}\n\n` : ""
  return `${prefix}Usage: /nih-scanner [scope] [--min-usage=N] [--max-candidates=1..100] [--workers=1..16] [--languages=ts,py,...]`
}

function parseOptions(raw: string): Options | string {
  const options: Options = { ...DEFAULT_OPTIONS }
  const positionals: string[] = []

  for (const token of raw.trim().split(/\s+/).filter(Boolean)) {
    if (token.startsWith("--min-usage=")) {
      const value = Number(token.slice("--min-usage=".length))
      if (!Number.isInteger(value) || value < 0) return usage("min-usage must be an integer >= 0")
      options.minUsage = value
    } else if (token.startsWith("--max-candidates=")) {
      const value = Number(token.slice("--max-candidates=".length))
      if (!Number.isInteger(value) || value < 1 || value > 100) return usage("max-candidates must be an integer from 1 to 100")
      options.maxCandidates = value
    } else if (token.startsWith("--workers=")) {
      const value = Number(token.slice("--workers=".length))
      if (!Number.isInteger(value) || value < 1 || value > 16) return usage("workers must be an integer from 1 to 16")
      options.workers = value
    } else if (token.startsWith("--languages=")) {
      const languages = token.slice("--languages=".length).split(",").map((l) => l.trim()).filter(Boolean)
      if (!languages.length) return usage("languages must be a non-empty comma-separated list")
      options.languages = languages
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
  pi.registerCommand("nih-scanner", {
    description: "Run an evidence-ranked NIH (Not-Invented-Here) build-vs-buy audit through OMP's native workflow runner",
    handler: async (args, ctx) => {
      const options = parseOptions(String(args ?? ""))
      if (typeof options === "string") {
        ctx.ui.notify(options, "error")
        return
      }

      await pi.sendUserMessage(`workflowz

Run a Not-Invented-Here (NIH) build-vs-buy audit.

Scope: ${options.scope}
Minimum usage count: ${options.minUsage}
Maximum candidates: ${options.maxCandidates}
Scan workers: ${options.workers}
Languages: ${options.languages ? options.languages.join(", ") : "auto-detect"}

Build this as a deterministic task graph, not as a single review. First run one cheap detection pass over the scope to identify languages, dependency manifests, and file count. Split the scope into up to ${options.workers} chunks and fan out an nih-scanner agent per chunk to find candidate code that reinvents well-supported library functionality. Dedupe overlapping candidates by file, line, and function, drop candidates below the minimum usage count, and cap the surviving set at ${options.maxCandidates} candidates.

Then run an independent adversarial-skeptic verification task against every candidate, default-refute: a confirmation must name the specific replacement library and cite why the local code duplicates it, or it is refuted. A crashed verification keeps the candidate flagged low-confidence and needs-human, never silently confirmed.

Finally, synthesize a ranked findings table from only the confirmed candidates: category, file:line, function, usage count, replacement library, migration effort, confidence, and recommendation, plus a summary of counts by category and the single highest-leverage action. Never file issues, post comments, or modify production code during this audit — report only.

Return the ranked findings report, refuted candidates, and needs-human candidates.`)
      ctx.ui.notify("NIH scanner audit workflow queued.", "info")
    },
  })
}

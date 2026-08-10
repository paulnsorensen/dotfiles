// OMP adapter for the shared Claude/Codex doom-loop detector.

import { createRequire } from "node:module"
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

type Verdict = {
  action: "allow" | "observe" | "block" | "stop"
  message?: string
}

type Guard = {
  evaluate(event: Record<string, unknown>): Verdict
}

const require = createRequire(import.meta.url)
const CORE_PATH = `${process.env.HOME}/.claude/lib/doom-loop-guard.js`

export default function (pi: ExtensionAPI) {
  let agentRun = 0

  pi.on("agent_start", async () => {
    agentRun += 1
  })

  pi.on("tool_call", async (event, ctx) => {
    try {
      const sessionId = ctx.sessionManager.getSessionFile()
      if (!sessionId) return

      const guard = require(CORE_PATH) as Guard
      const verdict = guard.evaluate({
        harness: "omp",
        session_id: sessionId,
        scope_id: String(agentRun),
        invocation_id: event.toolCallId,
        tool_name: event.toolName,
        tool_input: event.input,
      })

      if (verdict.action === "allow") return
      if (verdict.action === "observe") {
        pi.sendMessage(
          {
            customType: "doom-loop",
            content: verdict.message ?? "Repeated identical tool call detected.",
            display: true,
          },
          { deliverAs: "steer" },
        )
        return
      }

      if (verdict.action === "stop") ctx.abort()
      return {
        block: true,
        reason: verdict.message ?? "Repeated identical tool call blocked.",
      }
    } catch (err) {
      console.warn("[doom-loop-guard] detector failed; allowing tool call", err)
      return
    }
  })
}

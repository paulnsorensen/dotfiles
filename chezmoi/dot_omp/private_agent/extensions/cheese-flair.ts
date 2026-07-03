// Cheese-flair extension — injects a rotating cheese-flair sample once per
// session by running the shared deployed hook script and adding its stdout as
// injected context (persisted + TUI-visible). This reuses the same script the
// Claude SessionStart hook runs, so both harnesses draw from one flair bank.
//
// Fails open: a missing or failing script is a no-op, never blocks startup.
// Modeled on the vendored rtk.ts extension structure.
//
// `session_start` cannot return an injected message (notification-only), so we
// use `before_agent_start` — the only lifecycle event that returns a persisted
// message — guarded to fire once, mirroring Claude's session-start injection.

import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent"

const FLAIR_SCRIPT = `${process.env.HOME}/.claude/hooks/session-start-cheese-flair.sh`
const FLAIR_TIMEOUT_MS = 3_000

export default function (pi: ExtensionAPI) {
  let injected = false

  pi.on("before_agent_start", async () => {
    if (injected) return
    injected = true // set before exec so a failure never retries every turn

    try {
      const result = await pi.exec("bash", [FLAIR_SCRIPT], { timeout: FLAIR_TIMEOUT_MS })
      const text = result.stdout.trim()
      if (result.killed || result.code !== 0 || text === "") return
      return {
        message: {
          customType: "cheese-flair",
          content: text,
          display: true,
        },
      }
    } catch (err) {
      console.warn("[cheese-flair] flair script failed; skipping injection", err)
      return
    }
  })
}

// Blocks sub-agent spawns that fork the entire transcript into every worker
// (`fork_turns: "all"`) — silently burns quota. Small integer fork counts and
// "none" are unaffected; only the literal "all" value is rejected.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

const SPAWN_TOOLS = new Set(["spawn_agent", "task"])
const REASON =
  "fork_turns:'all' forks the entire transcript into the worker and burns quota. Re-spawn with fork_turns:'none' (or a small integer only if this sub-task genuinely needs prior turns)."

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event) => {
    if (!SPAWN_TOOLS.has(event.toolName)) return
    if (event.input.fork_turns !== "all") return

    return { block: true, reason: REASON }
  })
}

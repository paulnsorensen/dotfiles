// Commit-hallouminate reminder extension. After a commit that leaves wiki or
// corpus changes uncommitted, inject a model-visible reminder to include the
// hallouminate knowledge files so they are not left behind.
//
// `session_stop` is the only OMP lifecycle event that can inject context back to
// the model (turn_end / agent_end are notification-only). Its result type
// SessionStopEventResult exposes `additionalContext`, the OMP-native
// model-visible continuation field.
//
// One classifier, three harness adapters: this reuses the SAME deployed hook
// script the Claude/Codex Stop hook runs (same pattern as cheese-flair.ts),
// invoked as `bash <script> --omp <session_id>` so it emits the bare reminder
// text on stdout. That keeps the git-detection + fire-once logic in one place.
//
// Fails open: a missing script, a non-zero exit, or empty output is a no-op and
// never blocks a turn. The script itself honors HALLOUMINATE_COMMIT_REMINDER=0.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

const SCRIPT = `${process.env.HOME}/.claude/hooks/commit-hallouminate-reminder.sh`
const SCRIPT_TIMEOUT_MS = 5_000

export default function (pi: ExtensionAPI) {
  pi.on("session_stop", async (event) => {
    // Never re-fire while already continuing from a prior stop-hook run.
    if (event.stop_hook_active) return

    try {
      const result = await pi.exec("bash", [SCRIPT, "--omp", event.session_id ?? ""], {
        timeout: SCRIPT_TIMEOUT_MS,
      })
      const text = result.stdout.trim()
      if (result.killed || result.code !== 0 || text === "") return
      return { additionalContext: text }
    } catch (err) {
      console.warn("[commit-hallouminate-reminder] script failed; skipping", err)
      return
    }
  })
}

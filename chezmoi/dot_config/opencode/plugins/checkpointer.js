// checkpointer opencode plugin — checkpoint coordinator state before compaction.
//
// Hooks `experimental.session.compacting` to save a lightweight state file to
// `.cheese/checkpoint/<iso-timestamp>.md` before context is trimmed, and injects
// a note into the compaction context so the compacted agent knows where to find
// the last checkpoint.
//
// Also hooks `session.compacted` to log that a checkpoint was created.
//
// Fail-open everywhere: if the checkpoints directory can't be created or a write
// fails, the plugin returns {} and does not block compaction.

import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";

export const Checkpointer = async (ctx) => {
  return {
    "experimental.session.compacting": async (input, output) => {
      const ts = new Date().toISOString().replace(/[:.]/g, "-");

      // Resolve checkpoints directory under DOTFILES_DIR or home
      const root = process.env.DOTFILES_DIR || join(homedir(), "Dev", "dotfiles");
      const checkpointDir = join(root, ".cheese", "checkpoint");

      let filePath;
      try {
        await mkdir(checkpointDir, { recursive: true });
        filePath = join(checkpointDir, `${ts}.md`);

        const state = [
          `# Checkpoint: ${ts}`,
          `**Timestamp**: ${new Date().toISOString()}`,
          `**Session**: ${process.env.OPENCODE_SESSION_ID || "unknown"}`,
          "",
          "## Coordinator State",
          "",
          "_This is a compaction checkpoint. See the coordinator checkpoint at ",
          ".cheese/coordinator/ for detailed phase state._",
          "",
          "## Recent Tasks",
          "",
          "_The compacted agent should read the most recent .cheese/coordinator/*.md ",
          "file on resume to recover full state._",
          "",
          `**last_checkpoint**: ${filePath}`,
        ].join("\n");

        await writeFile(filePath, state, "utf-8");
      } catch {
        // Fail-open: if we can't write a checkpoint, don't block compaction
        return {};
      }

      // Inject a note into the compaction context so the compacted agent
      // knows where to find the last checkpoint
      return {
        checkpoint: filePath,
        note: `State checkpointed to ${filePath}. On resume read this file.`,
      };
    },

    "session.compacted": async (input, output) => {
      // Non-blocking notification that compaction completed
      return {
        acknowledged: true,
        message: "Checkpoint created before compaction.",
      };
    },
  };
};

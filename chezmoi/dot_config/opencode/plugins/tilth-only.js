const nativeFileTools = new Set([
  "read",
  "edit",
  "write",
  "apply_patch",
  "grep",
  "glob",
  "list",
]);

export default async function tilthOnly() {
  return {
    "chat.message": async (_input, output) => {
      output.message.tools = {
        ...output.message.tools,
        read: false,
        edit: false,
        write: false,
        apply_patch: false,
        grep: false,
        glob: false,
        list: false,
      };
    },
    "tool.execute.before": async (input) => {
      if (nativeFileTools.has(input.tool)) {
        throw new Error(`Native file tool ${input.tool} is disabled; use Tilth instead.`);
      }
    },
  };
}

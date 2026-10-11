// OpenCode v2 native file tools. v1 `apply_patch` is now `patch`, and `read` also lists directories.
const nativeFileTools = ["read", "edit", "write", "patch", "grep", "glob"];
const blocked = new Set(nativeFileTools);

export default {
  id: "dotfiles.tilth-only",
  async setup(ctx) {
    await ctx.tool.transform((editor) => {
      for (const id of nativeFileTools) editor.remove(id);
    });
    await ctx.tool.hook("execute.before", (event) => {
      if (blocked.has(event.tool)) {
        throw new Error(`Native file tool ${event.tool} is disabled; use Tilth instead.`);
      }
    });
  },
};

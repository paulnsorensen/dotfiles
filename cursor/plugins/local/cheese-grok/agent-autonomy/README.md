# Cursor agent autonomy (Auto-review)

Tracked source for a balanced Cursor Auto-review policy tuned for this
dotfiles stack: `rtk`, tilth, hallouminate, milknado / easy-cheese,
context7, and tavily.

Live Cursor config under `~/.cursor/` is gitignored (that tree is the
`cursor/` symlink target). Edit the files here, then apply:

```bash
./cursor/plugins/local/cheese-grok/agent-autonomy/apply.sh
```

Then fully quit and reopen Cursor. Keep **Settings → Agents → Approvals
& Execution** on Auto-review (this package does not enable Run
Everything).

| File | Installs to |
|---|---|
| `permissions.json` | `~/.cursor/permissions.json` (Auto-review allow/block instructions) |
| `sandbox.json` | `~/.cursor/sandbox.json` (extra paths + network default allow) |
| `apply.sh` | also expands IDE shell + MCP allowlists in `state.vscdb` |

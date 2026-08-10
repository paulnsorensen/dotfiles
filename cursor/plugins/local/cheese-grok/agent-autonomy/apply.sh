#!/usr/bin/env bash
# Install Cursor Auto-review + sandbox policy for the rtk/tilth/hallouminate/
# easy-cheese stack, and expand the IDE shell/MCP allowlists.
#
# Source of truth (tracked):
#   cursor/plugins/local/cheese-grok/agent-autonomy/
# Live targets (gitignored ~/.cursor symlink tree):
#   ~/.cursor/permissions.json
#   ~/.cursor/sandbox.json
#   Cursor composerState allowlists in state.vscdb
#
# Usage:
#   ./cursor/plugins/local/cheese-grok/agent-autonomy/apply.sh
#
# Safe to re-run. Backs up state.vscdb before mutating allowlists.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CURSOR_HOME="${CURSOR_HOME:-$HOME/.cursor}"
DB="${CURSOR_STATE_DB:-$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb}"
KEY='src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser'

[[ -f "$ROOT/permissions.json" ]] || { echo "missing $ROOT/permissions.json" >&2; exit 1; }
[[ -f "$ROOT/sandbox.json" ]] || { echo "missing $ROOT/sandbox.json" >&2; exit 1; }
[[ -f "$DB" ]] || { echo "missing Cursor state db: $DB" >&2; exit 1; }

mkdir -p "$CURSOR_HOME"
install -m 644 "$ROOT/permissions.json" "$CURSOR_HOME/permissions.json"
install -m 644 "$ROOT/sandbox.json" "$CURSOR_HOME/sandbox.json"
echo "installed $CURSOR_HOME/permissions.json"
echo "installed $CURSOR_HOME/sandbox.json"

TS="$(date +%Y%m%d-%H%M%S)"
cp "$DB" "${DB}.bak-perms-${TS}"
echo "backed up state.vscdb -> ${DB}.bak-perms-${TS}"

python3 - "$DB" "$KEY" <<'PY'
import json, sqlite3, sys

db, key = sys.argv[1], sys.argv[2]

shell_allow = sorted(set([
    "cat", "create_one", "echo", "gh", "mktemp", "set", "true", "git", "head",
    "mkdir", "python3",
    "rtk", "ls", "find", "rg", "fd", "jq", "yq", "node", "npm", "npx", "uv",
    "uvx", "python", "mise", "just", "dots", "cargo", "go", "tokei", "bat",
    "delta", "prek", "pretk", "awk", "sed", "sort", "uniq", "wc", "tr", "cut",
    "tee", "xargs", "env", "printf", "basename", "dirname", "realpath", "touch",
    "cp", "mv", "ln", "chmod", "tree", "file", "stat", "tail", "diff", "patch",
    "which", "command", "type", "test", "false", "hallouminate", "tilth",
    "serena", "brew", "curl", "wget", "bash", "zsh", "sh", "tar", "unzip",
    "zip", "open", "pbcopy", "pbpaste", "date", "uname", "whoami", "pwd",
]))

def expand(server, tools):
    out = []
    for s in {server, f"user-{server}", f"plugin-{server}-{server}", f"plugin-{server}"}:
        for t in tools:
            out.append(f"{s}:{t}")
        out.append(f"{s}:*")
    return out

tilth_tools = [
    "tilth_search", "tilth_read", "tilth_list", "tilth_deps", "tilth_grok",
    "tilth_diff", "tilth_write", "tilth_files",
]
hallou_tools = [
    "add_markdown", "backlinks", "corpus_stats", "delete_markdown",
    "get_footnote", "ground", "index", "list_corpora", "list_files",
    "list_tree", "read_markdown",
]
milknado_tools = [
    "milknado_archive_node", "milknado_unarchive_node", "milknado_delete_node",
    "milknado_deposit_result", "milknado_deposit_review", "milknado_edit_node",
    "milknado_get_node", "milknado_github_roadmap_bind",
    "milknado_github_roadmap_export", "milknado_github_roadmap_import",
    "milknado_goal_claim", "milknado_goal_release", "milknado_graph_summary",
    "milknado_move_node", "milknado_node_verify", "milknado_plan_apply",
    "milknado_plan_batches", "milknado_rebalance", "milknado_roadmap_export",
    "milknado_roadmap_import", "milknado_run_cancel", "milknado_run_inline",
    "milknado_run_inline_poll", "milknado_run_inline_start", "milknado_run_list",
    "milknado_run_loop_poll", "milknado_run_loop_start",
    "milknado_set_subtree_status", "milknado_todo_add", "milknado_todo_brief",
    "milknado_todo_claim", "milknado_todo_next", "milknado_todo_set_status",
    "milknado_todo_tree", "milknado_track_follow_up",
]
context7_tools = ["resolve-library-id", "query-docs"]
tavily_tools = [
    "tavily_search", "tavily_extract", "tavily_crawl", "tavily_map",
    "tavily_research",
]

mcp_allow = []
mcp_allow += expand("tilth", tilth_tools)
mcp_allow += expand("hallouminate", hallou_tools)
mcp_allow += [f"plugin-hallouminate-hallouminate:{t}" for t in hallou_tools]
mcp_allow += ["plugin-hallouminate-hallouminate:*"]
mcp_allow += expand("milknado", milknado_tools)
mcp_allow += [f"plugin-milknado-milknado:{t}" for t in milknado_tools]
mcp_allow += ["plugin-milknado-milknado:*"]
mcp_allow += expand("context7", context7_tools)
mcp_allow += expand("tavily", tavily_tools)
mcp_allow += [
    "code-review-graph:get_minimal_context_tool",
    "code-review-graph:*",
]
mcp_allow = sorted(set(mcp_allow))

con = sqlite3.connect(db)
cur = con.cursor()
raw = cur.execute("SELECT value FROM ItemTable WHERE key=?", (key,)).fetchone()
if not raw:
    raise SystemExit(f"missing reactive storage key: {key}")
obj = json.loads(raw[0] if isinstance(raw[0], str) else raw[0].decode())
cs = obj["composerState"]
before_shell = len(cs.get("yoloCommandAllowlist") or [])
before_mcp = len(cs.get("mcpAllowedTools") or [])
cs["yoloCommandAllowlist"] = shell_allow
cs["mcpAllowedTools"] = mcp_allow
cs["yoloEnableRunEverything"] = False
for mode in cs.get("modes4") or []:
    if mode.get("id") == "agent":
        mode["autoRun"] = True
        mode["smartModeAutoRun"] = True
        mode["fullAutoRun"] = False
obj["composerState"] = cs
cur.execute(
    "UPDATE ItemTable SET value=? WHERE key=?",
    (json.dumps(obj, separators=(",", ":"), ensure_ascii=False), key),
)
con.commit()
con.close()
print(f"shell allowlist: {before_shell} -> {len(shell_allow)}")
print(f"mcp allowlist:   {before_mcp} -> {len(mcp_allow)}")
print("Agent mode: autoRun=true, smartModeAutoRun=true, fullAutoRun=false")
PY

echo
echo "Done. Fully quit and reopen Cursor (or reload the window) so Auto-review picks up permissions.json / sandbox.json."
echo "Confirm under Settings → Agents → Approvals & Execution that mode is still Auto-review (not Run Everything)."

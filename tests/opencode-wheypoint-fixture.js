import { execFileSync } from "node:child_process";
import { copyFileSync, mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const sandbox = mkdtempSync(join(tmpdir(), "opencode-wheypoint-test-"));
const pluginDir = join(sandbox, "plugins");
const libDir = join(sandbox, "lib");
mkdirSync(pluginDir);
mkdirSync(libDir);
writeFileSync(join(sandbox, "package.json"), '{"type":"module"}');
copyFileSync(new URL("../chezmoi/dot_config/opencode/plugins/wheypoint-idle.js", import.meta.url), join(pluginDir, "wheypoint-idle.js"));
copyFileSync(new URL("../agents/lib/wheypoint-stop-gate.cjs", import.meta.url), join(libDir, "wheypoint-stop-gate.cjs"));
const { default: plugin } = await import(pathToFileURL(join(pluginDir, "wheypoint-idle.js")));

export { plugin };
export const WRITE = "Work remains. Write a wheypoint with /wheypoint, then stop.";
export const UPDATE = "Update this session's wheypoint with /wheypoint, then stop.";
export const started = { type: "session.execution.started", data: { sessionID: "root" } };
export const succeeded = { type: "session.execution.succeeded", data: { sessionID: "root" } };

export function user(id, text) {
  return { type: "user", id, text, time: { created: 1 } };
}
export function assistant(id, content, extra = {}) {
  return { type: "assistant", id, content: typeof content === "string" ? [{ type: "text", text: content }] : content, time: { created: 1, completed: 1 }, ...extra };
}
export function tool(id, name, input, content = [{ type: "text", text: "applied" }], time = 2) {
  return { type: "tool", id, name, state: { status: "completed", input, content }, time: { created: time, completed: time } };
}
export function synthetic(id, text) {
  return { type: "synthetic", id, text, time: { created: 1 } };
}
export function compaction(id) {
  return { type: "compaction", id, status: "completed", time: { created: 1 } };
}
export function root() {
  return [user("user-1", "Implement a.js"), assistant("reply-1", [tool("edit-1", "tilth_tilth_write",
    { edits: [{ path: "a.js", ops: [{ op: "create_file", content: "a" }] }] },
    [{ type: "text", text: "## a.js\napplied" }])])];
}
export async function settle() {
  for (let i = 0; i < 30; i++) await new Promise((resolve) => setImmediate(resolve));
}
function stream() {
  const queue = [];
  let wake;
  return {
    push(event) { queue.push(event); wake?.(); },
    async *subscribe({ signal }) {
      while (!signal.aborted) {
        if (queue.length) { yield queue.shift(); continue; }
        await new Promise((resolve) => {
          wake = resolve;
          signal.addEventListener("abort", resolve, { once: true });
        });
      }
    },
  };
}
function record(calls, name, result) {
  return async (arg) => { calls[name].push(arg); return result(arg); };
}
function sessionStub(calls, state) {
  return {
    get: record(calls, "get", (arg) => ({ id: arg.sessionID, parentID: arg.sessionID === "root" ? state.parentID : state.childParentID })),
    context: record(calls, "context", (arg) => (arg.sessionID === "root" ? state.messages : state.children[arg.sessionID] ?? [])),
    synthetic: record(calls, "synthetic", (arg) => {
      state.messages.push(synthetic(`synthetic-${calls.synthetic.length}`, arg.text));
      return { id: "inbox-2" };
    }),
  };
}
export function fixture(messages, options = {}) {
  const calls = { get: [], context: [], synthetic: [], logs: [] };
  const directory = mkdtempSync(join(sandbox, "repo-"));
  execFileSync("git", ["init", "-q", directory]);
  if (options.dirty !== false) writeFileSync(join(directory, "changed.txt"), "change");
  const state = { messages, parentID: undefined, childParentID: "root", children: {} };
  const events = stream();
  const ctx = { location: { directory }, event: { subscribe: (settings) => events.subscribe(settings) }, session: sessionStub(calls, state) };
  const cleanups = [];
  const load = async () => cleanups.push(await plugin.setup(ctx));
  const emit = async (event = succeeded) => { events.push(event); await settle(); };
  const start = async () => { if (!cleanups.length) await load(); await emit(started); await emit(succeeded); };
  const stop = () => cleanups.forEach((cleanup) => cleanup());
  return { calls, state, ctx, emit, load, start, stop, directory };
}
export async function quietly(calls, body) {
  const originalError = console.error;
  console.error = (...args) => calls.logs.push(args);
  try { await body(); } finally { console.error = originalError; }
}

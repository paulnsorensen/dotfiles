import plugin from "../chezmoi/dot_config/opencode/plugins/wheypoint-idle.js";

export { plugin };
export const WRITE = "Work remains. Write a wheypoint with /wheypoint, then stop.";
export const UPDATE = "Update this session's wheypoint with /wheypoint, then stop.";
export const started = { type: "session.execution.started", data: { sessionID: "root" } };
export const succeeded = { type: "session.execution.succeeded", data: { sessionID: "root" } };

export function user(id, text) {
  return { type: "user", id, text, time: { created: 1 } };
}

export function assistant(id, text, extra = {}) {
  return { type: "assistant", id, content: [{ type: "text", text }], time: { created: 1, completed: 1 }, ...extra };
}

export function synthetic(id, text) {
  return { type: "synthetic", id, text, time: { created: 1 } };
}

export function compaction(id, summary, recent = "") {
  return { type: "compaction", id, status: "completed", reason: "auto", summary, recent, time: { created: 1 } };
}

export function root(text = "Implement a.js and b.js.") {
  return [user("user-1", text), assistant("reply-1", "I changed a.js. b.js remains.")];
}

export async function settle() {
  for (let i = 0; i < 30; i++) await new Promise((resolve) => setImmediate(resolve));
}

// One live subscriber at a time, like a restarted plugin; an aborted subscriber stops reading.
function stream() {
  const queue = [];
  let wake;
  return {
    push(event) {
      queue.push(event);
      wake?.();
    },
    async *subscribe({ signal }) {
      while (!signal.aborted) {
        if (queue.length) {
          yield queue.shift();
          continue;
        }
        await new Promise((resolve) => {
          wake = resolve;
          signal.addEventListener("abort", resolve, { once: true });
        });
      }
    },
  };
}

function record(calls, name, result) {
  return async (arg) => {
    calls[name].push(arg);
    return result(arg);
  };
}

// Fake v2 ctx.session: the root session holds state.messages; the checker child replies with state.verdict.
function sessionStub(calls, state) {
  return {
    get: record(calls, "get", (arg) => ({ id: arg.sessionID, parentID: arg.sessionID === "root" ? state.parentID : "root" })),
    context: record(calls, "context", (arg) => (arg.sessionID === "root" ? state.messages : state.child)),
    create: record(calls, "create", () => ({ id: "check-1" })),
    prompt: record(calls, "prompt", (arg) => {
      state.child = [user("check-user", arg.text), assistant("check-reply", state.verdict)];
      return { id: "inbox-1" };
    }),
    wait: record(calls, "wait", () => undefined),
    remove: record(calls, "remove", () => undefined),
    synthetic: record(calls, "synthetic", (arg) => {
      state.messages.push(synthetic(`synthetic-${calls.synthetic.length}`, arg.text));
      return { id: "inbox-2" };
    }),
  };
}

export function fixture(messages, verdict = "WRITE") {
  const calls = { get: [], context: [], create: [], prompt: [], wait: [], remove: [], synthetic: [], logs: [] };
  const state = { messages, verdict, child: [], parentID: undefined };
  const events = stream();
  const ctx = { event: { subscribe: (options) => events.subscribe(options) }, session: sessionStub(calls, state) };
  const cleanups = [];
  const load = async () => cleanups.push(await plugin.setup(ctx));
  const emit = async (event = succeeded) => {
    events.push(event);
    await settle();
  };
  // A real v2 turn publishes started at the start of the busy period and succeeded at its end.
  const start = async () => {
    if (!cleanups.length) await load();
    await emit(started);
    await emit(succeeded);
  };
  const stop = () => cleanups.forEach((cleanup) => cleanup());
  return { calls, state, ctx, emit, load, start, stop };
}

export async function quietly(calls, body) {
  const originalError = console.error;
  console.error = (...args) => calls.logs.push(args);
  try {
    await body();
  } finally {
    console.error = originalError;
  }
}

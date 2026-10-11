import assert from "node:assert/strict";
import test from "node:test";
import plugin from "../chezmoi/dot_config/opencode/plugins/wheypoint-idle.js";

const WRITE = "Work remains. Write a wheypoint with /wheypoint, then stop.";
const UPDATE = "Update this session's wheypoint with /wheypoint, then stop.";
const succeeded = { type: "session.execution.succeeded", data: { sessionID: "root" } };

function user(id, text) {
  return { type: "user", id, text, time: { created: 1 } };
}

function assistant(id, text, extra = {}) {
  return { type: "assistant", id, content: [{ type: "text", text }], time: { created: 1, completed: 1 }, ...extra };
}

function synthetic(id, text) {
  return { type: "synthetic", id, text, time: { created: 1 } };
}

async function settle() {
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

function fixture(messages, verdict = "WRITE") {
  const calls = { get: [], context: [], create: [], prompt: [], wait: [], synthetic: [], logs: [] };
  const state = { messages, verdict, child: [], parentID: undefined };
  const events = stream();
  const ctx = {
    event: { subscribe: (options) => events.subscribe(options) },
    session: {
      get: async (arg) => {
        calls.get.push(arg);
        return { id: arg.sessionID, parentID: arg.sessionID === "root" ? state.parentID : "root" };
      },
      context: async (arg) => {
        calls.context.push(arg);
        return arg.sessionID === "root" ? state.messages : state.child;
      },
      create: async (arg) => { calls.create.push(arg); return { id: "check-1" }; },
      prompt: async (arg) => {
        calls.prompt.push(arg);
        state.child = [user("check-user", arg.text), assistant("check-reply", state.verdict)];
        return { id: "inbox-1" };
      },
      wait: async (arg) => { calls.wait.push(arg); },
      synthetic: async (arg) => {
        calls.synthetic.push(arg);
        state.messages.push(synthetic(`synthetic-${calls.synthetic.length}`, arg.text));
        return { id: "inbox-2" };
      },
    },
  };
  const cleanups = [];
  const load = async () => {
    const cleanup = await plugin.setup(ctx);
    cleanups.push(cleanup);
  };
  const emit = async (event = succeeded) => {
    events.push(event);
    await settle();
  };
  const start = async () => {
    if (!cleanups.length) await load();
    await emit();
  };
  const stop = () => cleanups.forEach((cleanup) => cleanup());
  return { calls, state, ctx, emit, load, start, stop };
}

function root(text = "Implement a.js and b.js.") {
  return [user("user-1", text), assistant("reply-1", "I changed a.js. b.js remains.")];
}

test("plugin exports one v2 definition", () => {
  assert.equal(plugin.id, "dotfiles.wheypoint-idle");
  assert.equal(typeof plugin.setup, "function");
});

test("unfinished root sends one marked WRITE through the hidden checker", async () => {
  const f = fixture(root());
  await f.start();
  assert.deepEqual(f.calls.create, [{ parentID: "root", title: "Wheypoint check", agent: "wheypoint-check", metadata: { source: "wheypoint-idle" } }]);
  assert.equal(f.calls.prompt[0].sessionID, "check-1");
  assert.match(f.calls.prompt[0].text, /a\.js and b\.js/);
  assert.match(f.calls.prompt[0].text, /pause or question.*not completion/i);
  assert.match(f.calls.prompt[0].text, /UPDATE.*WRITE.*ALLOW/s);
  assert.deepEqual(f.calls.wait, [{ sessionID: "check-1" }]);
  assert.deepEqual(f.calls.synthetic, [{
    sessionID: "root",
    text: `[[opencode-wheypoint-idle:user-1]]\n${WRITE}`,
    description: "Wheypoint follow-up",
    metadata: { source: "wheypoint-idle", turn: "user-1" },
  }]);
  f.stop();
});

test("UPDATE is sent after completed work or changed decisions despite completion", async () => {
  for (const text of ["Finished all named files after /wheypoint.", "Changed the architecture decision after Wheypoint dropped:"]) {
    const f = fixture([user("user-1", "Implement a.js"), assistant("a-1", "Wheypoint dropped:"), user("user-2", text), assistant("a-2", "Complete.")], "UPDATE");
    await f.start();
    assert.equal(f.calls.synthetic.length, 1);
    assert.equal(f.calls.synthetic[0].text, `[[opencode-wheypoint-idle:user-2]]\n${UPDATE}`);
    f.stop();
  }
});

test("pause or question with unfinished work still reaches checker", async () => {
  for (const text of ["Pause now, b.js is still unfinished.", "What about b.js? It still needs work."]) {
    const f = fixture([user("user-1", "Implement a.js and b.js."), assistant("a-1", "a.js done."), user("user-2", text), assistant("a-2", "I will stop.")]);
    await f.start();
    assert.equal(f.calls.prompt.length, 1);
    assert.equal(f.calls.synthetic.length, 1);
    f.stop();
  }
});

test("long history keeps the first request and checkpoint in a bounded packet", async () => {
  const history = [user("user-1", "Implement alpha.js, beta.js, and gamma.js.")];
  for (let i = 0; i < 80; i++) {
    history.push(assistant(`reply-${i}`, i === 2 ? "Wheypoint dropped: initial plan" : "Progress ".repeat(200)));
  }
  const f = fixture(history, "UPDATE");
  await f.start();
  const packet = f.calls.prompt[0].text;
  assert.match(packet, /alpha\.js, beta\.js, and gamma\.js/);
  assert.match(packet, /Wheypoint dropped: initial plan/);
  assert.match(packet, /[1-9][0-9]* omitted/);
  assert.ok(packet.length < 32000, packet.length);
  f.stop();
});

test("pure Q&A, cancellation, and completed unchanged allow idle", async () => {
  for (const text of ["What is a wheypoint?", "Cancel the remaining work.", "All requested work is complete; no changes after checkpoint."]) {
    const f = fixture([user("user-1", text), assistant("a-1", "Done.")], "ALLOW");
    await f.start();
    assert.equal(f.calls.synthetic.length, 0);
    f.stop();
  }
});

test("errored, incomplete, failed, interrupted, and child sessions do not call checker", async () => {
  for (const extra of [{ error: { type: "provider", message: "failed" } }, { time: { created: 1 } }]) {
    const f = fixture([user("user-1", "Implement a.js"), assistant("a-1", "Stopped", extra)]);
    await f.start();
    assert.equal(f.calls.create.length, 0);
    f.stop();
  }
  for (const type of ["session.execution.failed", "session.execution.interrupted"]) {
    const f = fixture(root());
    await f.load();
    await f.emit({ type, data: { sessionID: "root" } });
    assert.equal(f.calls.get.length, 0, type);
    f.stop();
  }
  const f = fixture(root());
  f.state.parentID = "other";
  await f.start();
  assert.equal(f.calls.create.length, 0);
  f.stop();
});

test("persisted synthetic follow-up suppresses duplicates after restart; next turn remains eligible", async () => {
  const f = fixture(root());
  await f.start();
  await f.emit();
  assert.equal(f.calls.synthetic.length, 1);
  f.state.messages.push(assistant("reply-f", "Wheypoint dropped: b.js remains."));
  f.stop();
  await f.load();
  const gets = f.calls.get.length;
  await f.emit();
  assert.equal(f.calls.get.length, gets + 1);
  assert.equal(f.calls.create.length, 1);
  assert.equal(f.calls.synthetic.length, 1);
  f.state.messages.push(user("user-2", "Continue b.js"), assistant("reply-2", "Still working."));
  await f.emit();
  assert.equal(f.calls.synthetic.length, 2);
  assert.equal(f.calls.synthetic[1].text, `[[opencode-wheypoint-idle:user-2]]\n${WRITE}`);
  f.stop();
});

test("a real user quoting the marker is not a follow-up", async () => {
  const f = fixture([user("user-1", `[[opencode-wheypoint-idle:user-1]]\n${WRITE}`), assistant("a-1", "Not done.")]);
  await f.start();
  assert.equal(f.calls.synthetic.length, 1);
  f.stop();
});

test("other synthetic notices are neither follow-ups nor real turns", async () => {
  const f = fixture([user("user-1", "Implement a.js"), assistant("a-1", "Started."), synthetic("s-1", "Subagent finished."), assistant("a-2", "a.js remains.")]);
  await f.start();
  assert.match(f.calls.prompt[0].text, /synthetic s-1: Subagent finished\./);
  assert.equal(f.calls.synthetic[0].text, `[[opencode-wheypoint-idle:user-1]]\n${WRITE}`);
  f.stop();
});

test("non-conversation messages do not hide the completed assistant turn", async () => {
  const f = fixture([user("user-1", "Implement a.js"), assistant("a-1", "a.js remains."), { type: "idle", id: "idle-1", outcome: "succeeded" }]);
  await f.start();
  assert.equal(f.calls.synthetic.length, 1);
  f.stop();
});

test("concurrent idle and a newer turn suppress stale send", async () => {
  const f = fixture(root());
  let release;
  let entered;
  const enteredPrompt = new Promise((resolve) => { entered = resolve; });
  let activeGets = 0;
  let maxGets = 0;
  f.ctx.session.get = async (arg) => {
    f.calls.get.push(arg);
    activeGets++;
    maxGets = Math.max(maxGets, activeGets);
    await new Promise((resolve) => setImmediate(resolve));
    activeGets--;
    return { id: arg.sessionID };
  };
  f.ctx.session.prompt = async (arg) => {
    f.calls.prompt.push(arg);
    if (f.calls.prompt.length === 1) {
      await new Promise((resolve) => { release = resolve; entered(); });
      f.state.child = [assistant("check-reply", "WRITE")];
    } else {
      f.state.child = [assistant("check-reply-2", "ALLOW")];
    }
    return { id: "inbox" };
  };
  await f.load();
  f.emit();
  await enteredPrompt;
  f.emit();
  f.emit();
  f.emit();
  f.state.messages.push(user("user-2", "New instruction"), assistant("reply-2", "Working."));
  release();
  await settle();
  await settle();
  assert.equal(maxGets, 1);
  assert.equal(f.calls.prompt.length, 2);
  assert.equal(f.calls.synthetic.length, 0);
  f.stop();
});

test("a started execution suppresses the follow-up", async () => {
  const f = fixture(root());
  const prompt = f.ctx.session.prompt;
  f.ctx.session.prompt = async (arg) => {
    const result = await prompt(arg);
    await f.emit({ type: "session.execution.started", data: { sessionID: "root" } });
    return result;
  };
  await f.start();
  await settle();
  assert.equal(f.calls.prompt.length, 1);
  assert.equal(f.calls.synthetic.length, 0);
  f.stop();
});

test("API and malformed checker failures do not crash or hot-loop", async () => {
  const originalError = console.error;
  console.error = () => {};
  try {
    for (const method of ["get", "context", "create", "prompt", "wait", "synthetic"]) {
      const f = fixture(root());
      f.ctx.session[method] = async (arg) => {
        f.calls[method].push(arg);
        throw new Error(method + " failed");
      };
      await f.start();
      await f.emit();
      assert.equal(f.calls[method].length, 1, method);
      f.stop();
    }
    const f = fixture(root(), "Probably WRITE");
    await f.start();
    await f.emit();
    assert.equal(f.calls.prompt.length, 1);
    assert.equal(f.calls.synthetic.length, 0);
    f.stop();
  } finally {
    console.error = originalError;
  }
});

test("queued idle events log one failure before a turn is known; a new user turn re-arms", async () => {
  const f = fixture(root());
  let release;
  let entered;
  const enteredGet = new Promise((resolve) => { entered = resolve; });
  f.ctx.session.get = async (arg) => {
    f.calls.get.push(arg);
    if (f.calls.get.length === 1) await new Promise((resolve) => { release = resolve; entered(); });
    throw new Error("get failed");
  };
  const originalError = console.error;
  console.error = (...args) => { f.calls.logs.push(args); };
  try {
    await f.load();
    f.emit();
    await enteredGet;
    f.emit();
    f.emit();
    release();
    await settle();
    assert.equal(f.calls.get.length, 1);
    assert.equal(f.calls.logs.length, 1);
    await f.emit({ type: "session.inbox.enqueued", data: { sessionID: "root", item: { type: "user" } } });
    await f.emit();
    assert.equal(f.calls.get.length, 2);
  } finally {
    console.error = originalError;
    f.stop();
  }
});

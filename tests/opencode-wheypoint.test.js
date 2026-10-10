import assert from "node:assert/strict";
import test from "node:test";
import plugin from "../chezmoi/dot_config/opencode/plugins/wheypoint-idle.js";

const WRITE = "Work remains. Write a wheypoint with /wheypoint, then stop.";
const UPDATE = "Update this session's wheypoint with /wheypoint, then stop.";

function user(id, text, synthetic = false) {
  return { info: { id, role: "user" }, parts: [{ type: "text", text, synthetic }] };
}

function assistant(id, text, extra = {}) {
  return {
    info: { id, role: "assistant", time: { completed: 1 }, ...extra },
    parts: [{ type: "text", text }],
  };
}

function fixture(messages, verdict = "WRITE") {
  const calls = { get: [], messages: [], create: [], prompt: [], promptAsync: [], status: [], logs: [] };
  const state = { messages, verdict, status: { root: { type: "idle" } }, parentID: undefined };
  const client = {
    session: {
      get: async (arg) => { calls.get.push(arg); return { data: { id: arg.path.id, parentID: state.parentID } }; },
      messages: async (arg) => { calls.messages.push(arg); return { data: state.messages }; },
      create: async (arg) => { calls.create.push(arg); return { data: { id: "check-1" } }; },
      prompt: async (arg) => {
        calls.prompt.push(arg);
        return { data: assistant("check-reply", state.verdict) };
      },
      promptAsync: async (arg) => {
        calls.promptAsync.push(arg);
        const part = arg.body.parts[0];
        state.messages.push(user("synthetic-1", part.text, part.synthetic));
        return { data: undefined };
      },
      status: async (arg) => { calls.status.push(arg); return { data: state.status }; },
    },
  };
  const event = { event: { type: "session.idle", properties: { sessionID: "root" } } };
  let hooks;
  const start = async () => {
    hooks ??= await plugin({ client });
    return hooks.event(event);
  };
  return { calls, state, client, event, start };
}

function root(text = "Implement a.js and b.js.") {
  return [user("user-1", text), assistant("reply-1", "I changed a.js. b.js remains.")];
}

test("unfinished root sends one marked WRITE with the exact reason and no tools", async () => {
  const f = fixture(root());
  await f.start();
  assert.equal(f.calls.create.length, 1);
  assert.deepEqual(f.calls.create[0], { body: { parentID: "root", title: "Wheypoint check" } });
  assert.equal(f.calls.prompt[0].path.id, "check-1");
  assert.equal(f.calls.prompt[0].body.agent, "wheypoint-check");
  assert.deepEqual(f.calls.prompt[0].body.tools, {});
  assert.match(f.calls.prompt[0].body.parts[0].text, /a\.js and b\.js/);
  assert.match(f.calls.prompt[0].body.parts[0].text, /pause or question.*not completion/i);
  assert.match(f.calls.prompt[0].body.parts[0].text, /UPDATE.*WRITE.*ALLOW/s);
  assert.equal(f.calls.promptAsync.length, 1);
  assert.equal(f.calls.promptAsync[0].body.parts[0].synthetic, true);
  assert.equal(f.calls.promptAsync[0].body.parts[0].text, `[[opencode-wheypoint-idle:user-1]]\n${WRITE}`);
});

test("UPDATE is sent after completed work or changed decisions despite completion", async () => {
  for (const text of ["Finished all named files after /wheypoint.", "Changed the architecture decision after Wheypoint dropped:"]) {
    const f = fixture([user("user-1", "Implement a.js"), assistant("a-1", "Wheypoint dropped:"), user("user-2", text), assistant("a-2", "Complete.")], "UPDATE");
    await f.start();
    assert.equal(f.calls.promptAsync.length, 1);
    assert.equal(f.calls.promptAsync[0].body.parts[0].text, `[[opencode-wheypoint-idle:user-2]]\n${UPDATE}`);
  }
});

test("pause or question with unfinished work still reaches checker", async () => {
  for (const text of ["Pause now, b.js is still unfinished.", "What about b.js? It still needs work."]) {
    const f = fixture([user("user-1", "Implement a.js and b.js."), assistant("a-1", "a.js done."), user("user-2", text), assistant("a-2", "I will stop.")]);
    await f.start();
    assert.equal(f.calls.prompt.length, 1);
    assert.equal(f.calls.promptAsync.length, 1);
  }
});

test("long history keeps the first request and checkpoint in a bounded packet", async () => {
  const history = [user("user-1", "Implement alpha.js, beta.js, and gamma.js.")];
  for (let i = 0; i < 80; i++) {
    history.push(assistant(`reply-${i}`, i === 2 ? "Wheypoint dropped: initial plan" : "Progress ".repeat(200)));
  }
  const f = fixture(history, "UPDATE");
  await f.start();
  const packet = f.calls.prompt[0].body.parts[0].text;
  assert.match(packet, /alpha\.js, beta\.js, and gamma\.js/);
  assert.match(packet, /Wheypoint dropped: initial plan/);
  assert.match(packet, /[1-9][0-9]* omitted/);
  assert.ok(packet.length < 32000, packet.length);
});

test("pure Q&A, cancellation, and completed unchanged allow idle", async () => {
  for (const text of ["What is a wheypoint?", "Cancel the remaining work.", "All requested work is complete; no changes after checkpoint."]) {
    const f = fixture([user("user-1", text), assistant("a-1", "Done.")], "ALLOW");
    await f.start();
    assert.equal(f.calls.promptAsync.length, 0);
  }
});

test("error, abort, and child sessions do not call checker", async () => {
  for (const extra of [{ error: { name: "APIError" } }, { error: { name: "MessageAbortedError" } }, { time: { created: 1 } }]) {
    const f = fixture([user("user-1", "Implement a.js"), assistant("a-1", "Stopped", extra)]);
    await f.start();
    assert.equal(f.calls.create.length, 0);
  }
  const f = fixture(root());
  f.state.parentID = "other";
  await f.start();
  assert.equal(f.calls.create.length, 0);
});

test("active and persisted synthetic follow-up suppress duplicate after restart; next turn remains eligible", async () => {
  const f = fixture(root());
  await f.start();
  await f.start();
  assert.equal(f.calls.promptAsync.length, 1);
  const restarted = await plugin({ client: f.client });
  await restarted.event(f.event);
  assert.equal(f.calls.promptAsync.length, 1);
  f.state.messages.push(user("user-2", "Continue b.js"), assistant("reply-2", "Still working."));
  await restarted.event(f.event);
  assert.equal(f.calls.promptAsync.length, 2);
});

test("a real user quoting the marker is not synthetic", async () => {
  const f = fixture([user("user-1", "I saw [[opencode-wheypoint-idle:user-0]] in a log. Implement a.js."), assistant("a-1", "Not done.")]);
  await f.start();
  assert.equal(f.calls.promptAsync.length, 1);
});


test("mixed user parts remain a new real turn, including file and agent parts", async () => {
  for (const part of [
    { type: "text", text: "Continue b.js" },
    { type: "file", mime: "text/plain", url: "file:///b.js" },
    { type: "agent", name: "coder" },
  ]) {
    const f = fixture(root());
    await f.start();
    f.state.messages.push({
      info: { id: "user-2", role: "user" },
      parts: [{ type: "text", synthetic: true, text: `[[opencode-wheypoint-idle:user-2]]\n${WRITE}` }, part],
    }, assistant("reply-2", "b.js remains."));
    await f.start();
    assert.equal(f.calls.promptAsync.length, 2, part.type);
    assert.equal(f.calls.promptAsync[1].body.parts[0].text, `[[opencode-wheypoint-idle:user-2]]\n${WRITE}`, part.type);
  }
});

test("concurrent idle and a newer turn suppress stale send", async () => {
  const f = fixture(root());
  let release;
  let entered;
  const enteredPrompt = new Promise((resolve) => { entered = resolve; });
  let activeGets = 0;
  let maxGets = 0;
  f.client.session.get = async (arg) => {
    f.calls.get.push(arg);
    activeGets++;
    maxGets = Math.max(maxGets, activeGets);
    await new Promise((resolve) => setImmediate(resolve));
    activeGets--;
    return { data: { id: arg.path.id } };
  };
  f.client.session.prompt = async (arg) => {
    f.calls.prompt.push(arg);
    if (f.calls.prompt.length === 1) {
      await new Promise((resolve) => { release = resolve; entered(); });
      return { data: assistant("check-reply", "WRITE") };
    }
    return { data: assistant("check-reply-2", "ALLOW") };
  };
  const hooks = await plugin({ client: f.client });
  const first = hooks.event(f.event);
  await enteredPrompt;
  const second = hooks.event(f.event);
  const third = hooks.event(f.event);
  const fourth = hooks.event(f.event);
  f.state.messages.push(user("user-2", "New instruction"), assistant("reply-2", "Working."));
  release();
  await Promise.all([first, second, third, fourth]);
  assert.equal(maxGets, 1);
  assert.equal(f.calls.prompt.length, 2);
  assert.equal(f.calls.promptAsync.length, 0);
});

test("busy status suppresses follow-up", async () => {
  const f = fixture(root());
  f.state.status.root = { type: "busy" };
  await f.start();
  assert.equal(f.calls.promptAsync.length, 0);
});

test("SDK and malformed checker failures do not crash or hot-loop", async () => {
  for (const method of ["get", "messages", "create", "prompt", "status", "promptAsync"]) {
    const f = fixture(root());
    const original = f.client.session[method];
    f.client.session[method] = async (...args) => {
      f.calls[method].push(args[0]);
      return { error: new Error(method + " failed") };
    };
    await f.start();
    await f.start();
    assert.equal(f.calls[method].length, 1, method);
    f.client.session[method] = original;
  }
  const f = fixture(root(), "Probably WRITE");
  await f.start();
  await f.start();
  assert.equal(f.calls.prompt.length, 1);
  assert.equal(f.calls.promptAsync.length, 0);
});


test("queued idle events log one SDK failure before a turn is known", async () => {
  const f = fixture(root());
  let release;
  let entered;
  const enteredGet = new Promise((resolve) => { entered = resolve; });
  f.client.session.get = async (arg) => {
    f.calls.get.push(arg);
    if (f.calls.get.length === 1) await new Promise((resolve) => { release = resolve; entered(); });
    return { error: new Error("get failed") };
  };
  const hooks = await plugin({ client: f.client });
  const originalError = console.error;
  console.error = (...args) => { f.calls.logs.push(args); };
  try {
    const first = hooks.event(f.event);
    await enteredGet;
    const second = hooks.event(f.event);
    const third = hooks.event(f.event);
    release();
    await Promise.all([first, second, third]);
    assert.equal(f.calls.get.length, 1);
    assert.equal(f.calls.logs.length, 1);
  } finally {
    console.error = originalError;
  }
});

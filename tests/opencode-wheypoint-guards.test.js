import assert from "node:assert/strict";
import test from "node:test";
import { assistant, fixture, quietly, root, settle, started, tool, user } from "./opencode-wheypoint-fixture.js";

test("failed, incomplete, and child sessions do not send", async () => {
  for (const extra of [{ error: { type: "provider" } }, { time: { created: 1 } }]) {
    const f = fixture([user("user-1", "Edit"), assistant("a-1", [tool("edit", "tilth_tilth_write", { edits: [{ path: "a.js" }] }, [{ type: "text", text: "## a.js\napplied" }])], extra)]);
    await f.start();
    assert.equal(f.calls.synthetic.length, 0);
    f.stop();
  }
  const child = fixture(root());
  child.state.parentID = "another-root";
  await child.start();
  assert.equal(child.calls.synthetic.length, 0);
  child.stop();
});

test("a run that starts during evaluation suppresses the stale follow-up", async () => {
  const f = fixture(root());
  const context = f.ctx.session.context;
  f.ctx.session.context = async (arg) => {
    const result = await context(arg);
    if (f.calls.context.length === 1) await f.emit(started);
    return result;
  };
  await f.start();
  assert.equal(f.calls.synthetic.length, 0);
  f.stop();
});

test("a newer assistant reply suppresses the stale follow-up", async () => {
  const f = fixture(root());
  const context = f.ctx.session.context;
  f.ctx.session.context = async (arg) => {
    if (f.calls.context.length === 1) f.state.messages.push(assistant("a-2", "Newer reply."));
    return context(arg);
  };
  await f.start();
  assert.equal(f.calls.synthetic.length, 0);
  f.stop();
});

test("concurrent idle events serialize checks and send once", async () => {
  const f = fixture(root());
  let release;
  let entered;
  const blocked = new Promise((resolve) => { entered = resolve; });
  let active = 0;
  let peak = 0;
  f.ctx.session.get = async (arg) => {
    f.calls.get.push(arg);
    active++;
    peak = Math.max(peak, active);
    if (f.calls.get.length === 1) await new Promise((resolve) => { release = resolve; entered(); });
    active--;
    return { id: arg.sessionID };
  };
  await f.load();
  f.emit();
  await blocked;
  f.emit();
  f.emit();
  release();
  await settle();
  await settle();
  assert.equal(peak, 1);
  assert.equal(f.calls.synthetic.length, 1);
  f.stop();
});

test("API failure logs once per turn; a new user turn re-arms an early failure", async () => {
  const f = fixture(root());
  f.ctx.session.get = async (arg) => {
    f.calls.get.push(arg);
    throw new Error("get failed: private-token-sentinel");
  };
  await quietly(f.calls, async () => {
    await f.start();
    await f.emit();
    assert.equal(f.calls.get.length, 1);
    assert.deepEqual(f.calls.logs, [["wheypoint-idle: assessment failed"]]);
    await f.emit({ type: "session.inbox.enqueued", data: { sessionID: "root", item: { type: "user" } } });
    await f.emit();
    assert.equal(f.calls.get.length, 2);
    assert.deepEqual(f.calls.logs, [
      ["wheypoint-idle: assessment failed"],
      ["wheypoint-idle: assessment failed"],
    ]);
  });
  f.stop();
});

test("synthetic failure logs once and does not hot-loop", async () => {
  const f = fixture(root());
  f.ctx.session.synthetic = async (arg) => {
    f.calls.synthetic.push(arg);
    throw new Error("synthetic failed: private-token-sentinel");
  };
  await quietly(f.calls, async () => {
    await f.start();
    await f.emit();
    assert.equal(f.calls.synthetic.length, 1);
    assert.deepEqual(f.calls.logs, [["wheypoint-idle: assessment failed"]]);
  });
  f.stop();
});

test("event-stream failure logs a fixed message without the error", async () => {
  const f = fixture(root());
  f.ctx.event.subscribe = async function* () {
    throw new Error("stream failed: private-token-sentinel");
  };
  await quietly(f.calls, async () => {
    await f.load();
    await settle();
    assert.deepEqual(f.calls.logs, [["wheypoint-idle: event stream ended"]]);
  });
  f.stop();
});

test("shutdown while evaluation waits prevents a stale send", async () => {
  const f = fixture(root());
  let release;
  let entered;
  const blocked = new Promise((resolve) => { entered = resolve; });
  const context = f.ctx.session.context;
  f.ctx.session.context = async (arg) => {
    if (f.calls.context.length === 0) await new Promise((resolve) => { release = resolve; entered(); });
    return context(arg);
  };
  await f.load();
  f.emit();
  await blocked;
  f.stop();
  release();
  await settle();
  assert.equal(f.calls.synthetic.length, 0);
});

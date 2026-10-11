import assert from "node:assert/strict";
import test from "node:test";
import { assistant, fixture, quietly, root, settle, started, synthetic, user } from "./opencode-wheypoint-fixture.js";

// Runs action while the checker runs, then waits until the check can send.
function duringCheck(f, action) {
  const prompt = f.ctx.session.prompt;
  let finished;
  const done = new Promise((resolve) => { finished = resolve; });
  f.ctx.session.prompt = async (arg) => {
    const result = await prompt(arg);
    await action();
    finished();
    return result;
  };
  return async () => {
    await f.start();
    await done;
    await settle();
  };
}

test("errored, incomplete, and child sessions do not call the checker", async () => {
  for (const extra of [{ error: { type: "provider", message: "failed" } }, { time: { created: 1 } }]) {
    const f = fixture([user("user-1", "Implement a.js"), assistant("a-1", "Stopped", extra)]);
    await f.start();
    assert.equal(f.calls.create.length, 0);
    f.stop();
  }
  const f = fixture(root());
  f.state.parentID = "other";
  await f.start();
  assert.equal(f.calls.create.length, 0);
  f.stop();
});

test("a run that starts during the check suppresses the follow-up", async () => {
  const f = fixture(root());
  await duringCheck(f, () => f.emit(started))();
  assert.equal(f.calls.prompt.length, 1);
  assert.equal(f.calls.synthetic.length, 0);
  f.stop();
});

test("a failed or interrupted run during the check clears busy", async () => {
  for (const type of ["session.execution.failed", "session.execution.interrupted"]) {
    const f = fixture(root());
    await duringCheck(f, async () => {
      await f.emit(started);
      await f.emit({ type, data: { sessionID: "root" } });
    })();
    assert.equal(f.calls.synthetic.length, 1, type);
    f.stop();
  }
});

test("a newer assistant message without a user turn suppresses the stale send", async () => {
  const f = fixture(root());
  await duringCheck(f, () => f.state.messages.push(synthetic("s-1", "Subagent finished."), assistant("a-2", "Merged the subagent result.")))();
  assert.equal(f.calls.prompt.length, 1);
  assert.equal(f.calls.synthetic.length, 0);
  f.stop();
});

test("concurrent idle events and a newer turn suppress the stale send", async () => {
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

test("API failures and bad checker replies do not crash or hot-loop", async () => {
  for (const method of ["get", "context", "create", "prompt", "wait", "synthetic"]) {
    const f = fixture(root());
    f.ctx.session[method] = async (arg) => {
      f.calls[method].push(arg);
      throw new Error(method + " failed");
    };
    await quietly(f.calls, async () => {
      await f.start();
      await f.emit();
    });
    assert.equal(f.calls[method].length, 1, method);
    assert.equal(f.calls.logs.length, 1, method);
    f.stop();
  }
  const replies = [
    [assistant("check-reply", "Probably WRITE")],
    [assistant("check-reply", "WRITE", { error: { type: "provider", message: "failed" } })],
    [assistant("check-reply", "WRITE", { time: { created: 1 } })],
  ];
  for (const reply of replies) {
    const f = fixture(root());
    f.ctx.session.prompt = async (arg) => {
      f.calls.prompt.push(arg);
      f.state.child = reply;
    };
    await quietly(f.calls, async () => {
      await f.start();
      await f.emit();
    });
    assert.equal(f.calls.prompt.length, 1);
    assert.equal(f.calls.remove.length, 1);
    assert.equal(f.calls.synthetic.length, 0);
    f.stop();
  }
});

test("a failed check-session removal is logged and does not block the follow-up", async () => {
  const f = fixture(root());
  f.ctx.session.remove = async (arg) => {
    f.calls.remove.push(arg);
    throw new Error("remove failed");
  };
  await quietly(f.calls, () => f.start());
  assert.equal(f.calls.logs.length, 1);
  assert.equal(f.calls.synthetic.length, 1);
  f.stop();
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
  await quietly(f.calls, async () => {
    await f.load();
    f.emit();
    await enteredGet;
    f.emit();
    f.emit();
    // Let both events queue behind the blocked get before it fails.
    await settle();
    release();
    await settle();
    assert.equal(f.calls.get.length, 1);
    assert.equal(f.calls.logs.length, 1);
    await f.emit({ type: "session.inbox.enqueued", data: { sessionID: "root", item: { type: "user" } } });
    await f.emit();
    assert.equal(f.calls.get.length, 2);
  });
  f.stop();
});

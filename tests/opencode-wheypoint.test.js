import assert from "node:assert/strict";
import test from "node:test";
import { UPDATE, WRITE, assistant, compaction, fixture, plugin, root, tool, user } from "./opencode-wheypoint-fixture.js";

const checkpoint = (time = 2, output = { ok: true, command: "checkpoint" }) => {
  const call = tool("checkpoint", "shell", { command: "python wheypoint.pyz checkpoint" },
    [{ type: "text", text: JSON.stringify(output) }], time);
  call.state.metadata = { status: "completed", exit: 0 };
  return call;
};
const edit = (time = 3) => tool("edit", "tilth_tilth_write",
  { edits: [{ path: "a.js", ops: [{ op: "replace_text", old: "a", new: "b" }] }] },
  [{ type: "text", text: "## a.js\napplied" }], time);

test("plugin exports one v2 definition", () => {
  assert.equal(plugin.id, "dotfiles.wheypoint-idle");
  assert.equal(typeof plugin.setup, "function");
});

test("a successful tracked mutation and dirty tree sends one queued WRITE without a model call", async () => {
  const f = fixture(root());
  await f.start();
  assert.deepEqual(f.calls.synthetic, [{
    sessionID: "root",
    text: `[[opencode-wheypoint-idle:user-1]]\n${WRITE}`,
    description: "Wheypoint follow-up",
    metadata: { source: "wheypoint-idle", turn: "user-1" },
    delivery: "queue",
  }]);
  assert.deepEqual(Object.keys(f.ctx.session).sort(), ["context", "get", "synthetic"]);
  f.stop();
});

test("dirty pre-existing files and pure Q&A do not trigger a follow-up", async () => {
  const f = fixture([user("user-1", "What is a wheypoint?"), assistant("a-1", "It records state.")]);
  await f.start();
  assert.equal(f.calls.synthetic.length, 0);
  f.stop();
});

test("a confirmed checkpoint before a later mutation sends UPDATE even with a clean tree", async () => {
  const f = fixture([user("user-1", "Implement a.js"), assistant("a-1", [checkpoint(), edit()])], { dirty: false });
  await f.start();
  assert.equal(f.calls.synthetic[0].text, `[[opencode-wheypoint-idle:user-1]]\n${UPDATE}`);
  f.stop();
});

test("a checkpoint after the mutation clears the update request", async () => {
  const f = fixture([user("user-1", "Implement a.js"), assistant("a-1", [edit(2), checkpoint(3)])]);
  await f.start();
  assert.equal(f.calls.synthetic.length, 0);
  f.stop();
});

test("quoted markers and failed checkpoint output do not prove a checkpoint", async () => {
  for (const content of [
    [tool("edit", "tilth_tilth_write", { edits: [{ path: "a.js" }] }, [{ type: "text", text: "## a.js\napplied" }]), { type: "text", text: "Wheypoint dropped:" }],
    [checkpoint(2, { ok: false, command: "checkpoint" }), edit(3)],
  ]) {
    const f = fixture([user("user-1", "/wheypoint"), assistant("a-1", content)]);
    await f.start();
    assert.equal(f.calls.synthetic[0].text, `[[opencode-wheypoint-idle:user-1]]\n${WRITE}`);
    f.stop();
  }
});

test("a failed mutation and a clean tree do not request WRITE", async () => {
  const failed = tool("edit", "tilth_tilth_write", { edits: [{ path: "a.js" }] }, [{ type: "text", text: "## a.js\\nerror: denied" }]);
  for (const [messages, options] of [
    [[user("user-1", "Edit"), assistant("a-1", [failed])], {}],
    [root(), { dirty: false }],
  ]) {
    const f = fixture(messages, options);
    await f.start();
    assert.equal(f.calls.synthetic.length, 0);
    f.stop();
  }
});

test("native shell metadata decides whether a Git mutation completed", async () => {
  for (const [name, metadata, executed, state, expected] of [
    ["nonzero exit", { status: "completed", exit: 1 }, true, "completed", false],
    ["successful exit", { status: "completed", exit: 0 }, true, "completed", true],
    ["background", { status: "running" }, true, "completed", false],
    ["pending", { status: "running" }, true, "running", false],
    ["not executed", { status: "completed", exit: 0 }, false, "completed", false],
    ["signalled", { status: "completed", exit: 0, signal: "SIGTERM" }, true, "completed", false],
    ["timed out", { status: "completed", exit: 0, timeout: true }, true, "completed", false],
  ]) {
    const commit = tool("commit", "shell", { command: "git commit -m x" },
      [{ type: "text", text: metadata.exit === 1 ? "Exited with code 1" : "Command completed" }], 3);
    commit.executed = executed;
    commit.state.status = state;
    commit.state.metadata = metadata;
    const f = fixture([user("user-1", "Commit"), assistant("a-1", [checkpoint(), commit])], { dirty: false });
    await f.start();
    assert.equal(f.calls.synthetic.length, expected ? 1 : 0, name);
    if (expected) assert.equal(f.calls.synthetic[0].text, `[[opencode-wheypoint-idle:user-1]]\n${UPDATE}`);
    f.stop();
  }
});

test("only a completed direct child with verified parent contributes mutations", async () => {
  const dispatch = tool("dispatch", "subagent", { agent: "coder" }, [{ type: "text", text: "done" }]);
  dispatch.state.metadata = { sessionID: "child-1" };
  const messages = [user("user-1", "Edit"), assistant("a-1", [dispatch])];
  const f = fixture(messages);
  f.state.children["child-1"] = [assistant("child-a", [edit()])];
  await f.start();
  assert.equal(f.calls.synthetic[0].text, `[[opencode-wheypoint-idle:user-1]]\n${WRITE}`);
  f.stop();
  const foreign = fixture(messages);
  foreign.state.children["child-1"] = [assistant("child-a", [edit()])];
  foreign.state.childParentID = "another-root";
  await foreign.start();
  assert.equal(foreign.calls.synthetic.length, 0);
  foreign.stop();
});

test("child checkpoint and root mutation merge by completion time", async () => {
  const dispatch = tool("dispatch", "subagent", { agent: "coder" }, [{ type: "text", text: "done" }]);
  dispatch.state.metadata = { sessionID: "child-1" };
  const f = fixture([user("user-1", "Edit"), assistant("a-1", [dispatch, edit(3)])], { dirty: false });
  f.state.children["child-1"] = [assistant("child-a", [checkpoint(2)])];
  await f.start();
  assert.equal(f.calls.synthetic[0].text, `[[opencode-wheypoint-idle:user-1]]\n${UPDATE}`);
  f.stop();
});

test("compaction is a turn boundary and stored synthetic follow-up suppresses restart duplicates", async () => {
  const f = fixture([compaction("compact-1"), assistant("a-1", [edit()])]);
  await f.start();
  assert.equal(f.calls.synthetic[0].text, `[[opencode-wheypoint-idle:compact-1]]\n${WRITE}`);
  f.stop();
  await f.load();
  await f.emit();
  assert.equal(f.calls.synthetic.length, 1);
  f.state.messages.push(user("user-2", "Continue"), assistant("a-2", [edit()]));
  await f.emit();
  assert.equal(f.calls.synthetic.length, 2);
  f.stop();
});

test("a quoted marker from a real user cannot suppress a follow-up", async () => {
  const f = fixture([user("user-1", `[[opencode-wheypoint-idle:user-1]]\n${WRITE}`), assistant("a-1", [edit()])]);
  await f.start();
  assert.equal(f.calls.synthetic.length, 1);
  f.stop();
});

test("WHEYPOINT_STOP_GATE=0 disables the plugin", async () => {
  const old = process.env.WHEYPOINT_STOP_GATE;
  process.env.WHEYPOINT_STOP_GATE = "0";
  try {
    const f = fixture(root());
    await f.start();
    assert.equal(f.calls.synthetic.length, 0);
    f.stop();
  } finally {
    if (old === undefined) delete process.env.WHEYPOINT_STOP_GATE;
    else process.env.WHEYPOINT_STOP_GATE = old;
  }
});

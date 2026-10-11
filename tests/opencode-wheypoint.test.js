import assert from "node:assert/strict";
import test from "node:test";
import { UPDATE, WRITE, assistant, compaction, fixture, plugin, root, synthetic, user } from "./opencode-wheypoint-fixture.js";

test("plugin exports one v2 definition", () => {
  assert.equal(plugin.id, "dotfiles.wheypoint-idle");
  assert.equal(typeof plugin.setup, "function");
});

test("unfinished root sends one queued, marked WRITE through the hidden checker", async () => {
  const f = fixture(root());
  await f.start();
  assert.deepEqual(f.calls.create, [{ parentID: "root", title: "Wheypoint check", agent: "wheypoint-check", metadata: { source: "wheypoint-idle" } }]);
  assert.equal(f.calls.prompt[0].sessionID, "check-1");
  assert.match(f.calls.prompt[0].text, /a\.js and b\.js/);
  assert.match(f.calls.prompt[0].text, /pause or question.*not completion/i);
  assert.match(f.calls.prompt[0].text, /UPDATE.*WRITE.*ALLOW/s);
  assert.deepEqual(f.calls.wait, [{ sessionID: "check-1" }]);
  assert.deepEqual(f.calls.remove, [{ sessionID: "check-1" }]);
  assert.deepEqual(f.calls.synthetic, [{
    sessionID: "root",
    text: `[[opencode-wheypoint-idle:user-1]]\n${WRITE}`,
    description: "Wheypoint follow-up",
    metadata: { source: "wheypoint-idle", turn: "user-1" },
    delivery: "queue",
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

test("the checker packet carries the user's pause or question", async () => {
  for (const text of ["Pause now, b.js is still unfinished.", "What about b.js? It still needs work."]) {
    const f = fixture([user("user-1", "Implement a.js and b.js."), assistant("a-1", "a.js done."), user("user-2", text), assistant("a-2", "I will stop.")]);
    await f.start();
    assert.equal(f.calls.prompt.length, 1);
    assert.ok(f.calls.prompt[0].text.includes(text));
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

test("an ALLOW verdict sends no follow-up", async () => {
  const f = fixture([user("user-1", "What is a wheypoint?"), assistant("a-1", "Done.")], "ALLOW");
  await f.start();
  assert.equal(f.calls.prompt.length, 1);
  assert.equal(f.calls.synthetic.length, 0);
  f.stop();
});

test("a completed auto-compaction is the turn boundary when no user message remains", async () => {
  const f = fixture([compaction("compact-1", "Goal: implement a.js and b.js.", "a.js done."), assistant("a-1", "b.js remains.")]);
  await f.start();
  assert.match(f.calls.prompt[0].text, /Goal: implement a\.js and b\.js\./);
  assert.equal(f.calls.synthetic[0].text, `[[opencode-wheypoint-idle:compact-1]]\n${WRITE}`);
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

test("a follow-up is not mistaken for a checkpoint in the packet", async () => {
  const followup = synthetic("s-1", `[[opencode-wheypoint-idle:user-1]]\n${WRITE}`);
  const f = fixture([...root(), followup, assistant("a-2", "Still on b.js."), user("user-2", "Go on"), assistant("a-3", "b.js remains.")]);
  await f.start();
  assert.doesNotMatch(f.calls.prompt[0].text, /opencode-wheypoint-idle:user-1/);
  f.stop();
});

test("a marked synthetic notice with another reason is not a follow-up", async () => {
  const f = fixture([...root(), synthetic("s-1", "[[opencode-wheypoint-idle:user-1]]\nSubagent finished."), assistant("a-2", "b.js remains.")]);
  await f.start();
  assert.equal(f.calls.synthetic.length, 1);
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

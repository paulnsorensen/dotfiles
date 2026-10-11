import { execFileSync } from "node:child_process";
import gate from "../lib/wheypoint-stop-gate.cjs";

const marker = "[[opencode-wheypoint-idle:";
const reasons = {
  WRITE: "Work remains. Write a wheypoint with /wheypoint, then stop.",
  UPDATE: "Update this session's wheypoint with /wheypoint, then stop.",
};
const source = "wheypoint-idle";

function followupText(turn, reason) {
  return `${marker}${turn}]]\n${reason}`;
}

function followupTurn(message) {
  const text = message.text ?? "";
  if (message.type !== "synthetic" || !text.startsWith(marker)) return undefined;
  const end = text.indexOf("]]\n");
  const turn = text.slice(marker.length, end);
  return end > marker.length && Object.values(reasons).includes(text.slice(end + 3)) ? turn : undefined;
}

function turnStart(message) {
  return message.type === "user" || (message.type === "compaction" && message.status === "completed");
}

function conversation(messages) {
  return messages.filter((message) => ["user", "assistant", "synthetic"].includes(message.type) || turnStart(message));
}

function completedTurn(messages) {
  const last = messages.at(-1);
  const turn = messages.findLast(turnStart)?.id;
  if (!turn || last?.type !== "assistant" || !last.time?.completed || last.error) return undefined;
  return { turn, last };
}

function eventsFrom(messages) {
  const events = [];
  const children = new Set();
  for (const message of messages) {
    if (message.type === "shell") {
      const kind = gate.callKind("shell", { command: message.command });
      if (kind) events.push({ kind: kind === "checkpoint-call" ? "checkpoint" : kind,
        success: message.status === "exited" && message.exit === 0 &&
          (kind !== "checkpoint-call" || gate.checkpointSucceeded(message.output)),
        time: message.time?.completed });
    }
    if (message.type !== "assistant") continue;
    for (const part of message.content ?? []) {
      if (part.type !== "tool" || part.state?.status !== "completed") continue;
      if (part.name === "subagent" && typeof part.state.metadata?.sessionID === "string") {
        children.add(part.state.metadata.sessionID);
      }
      const kind = gate.callKind(part.name, part.state.input);
      if (!kind) continue;
      const output = { content: part.state.content };
      const shell = part.name !== "shell" || (part.executed !== false &&
        part.state.metadata?.status === "completed" && part.state.metadata.exit === 0 &&
        part.state.metadata.signal === undefined && part.state.metadata.timeout !== true);
      events.push({ kind: kind === "checkpoint-call" ? "checkpoint" : kind,
        success: shell && gate.mutationSucceeded(part.name, part.state.input, output) &&
          (kind !== "checkpoint-call" || gate.checkpointSucceeded(output)),
        time: part.time?.completed });
    }
  }
  return { events, children };
}

async function changes(ctx, sessionID, messages) {
  const root = eventsFrom(messages);
  const events = root.events;
  for (const childID of root.children) {
    const child = await ctx.session.get({ sessionID: childID });
    if (child.parentID !== sessionID) continue;
    events.push(...eventsFrom(await ctx.session.context({ sessionID: childID })).events);
  }
  events.forEach((event, index) => { event.index = index; });
  events.sort((a, b) => (a.time ?? 0) - (b.time ?? 0) || a.index - b.index);
  return gate.evaluateEvents(events);
}

function dirty(directory) {
  return execFileSync("git", ["-C", directory, "status", "--porcelain", "--", ".", ":(exclude).cheese"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim() !== "";
}

async function assess(ctx, state, sessionID) {
  let turn;
  try {
    if (process.env.WHEYPOINT_STOP_GATE === "0" || state.signal.aborted) return;
    if ((await ctx.session.get({ sessionID })).parentID) return;
    const history = await ctx.session.context({ sessionID });
    const messages = conversation(history);
    const checked = completedTurn(messages);
    turn = checked?.turn;
    if (!checked || state.consumed.get(sessionID) === turn || messages.some((m) => followupTurn(m) === turn)) return;
    state.consumed.set(sessionID, turn);
    const result = await changes(ctx, sessionID, history);
    let reason;
    if (result.changes && result.checkpoint) reason = reasons.UPDATE;
    else if (result.changes && dirty(ctx.location.directory)) reason = reasons.WRITE;
    if (!reason || state.signal.aborted) return;
    const current = completedTurn(conversation(await ctx.session.context({ sessionID })));
    if (current?.turn !== turn || current.last.id !== checked.last.id || state.busy.has(sessionID) || state.signal.aborted) return;
    await ctx.session.synthetic({
      sessionID,
      text: followupText(turn, reason),
      description: "Wheypoint follow-up",
      metadata: { source, turn },
      delivery: "queue",
    });
  } catch {
    if (!turn) state.failedBeforeTurn.add(sessionID);
    console.error("wheypoint-idle: assessment failed");
  }
}

function schedule(ctx, state, sessionID) {
  const task = (state.pending.get(sessionID) ?? Promise.resolve()).then(() => {
    if (!state.failedBeforeTurn.has(sessionID)) return assess(ctx, state, sessionID);
  });
  state.pending.set(sessionID, task);
  task.finally(() => {
    if (state.pending.get(sessionID) === task) state.pending.delete(sessionID);
  });
}

function handle(ctx, state, event) {
  const sessionID = event.data?.sessionID;
  if (!sessionID) return;
  if (event.type === "session.inbox.enqueued" && event.data.item?.type === "user") {
    state.failedBeforeTurn.delete(sessionID);
  } else if (event.type === "session.execution.started") {
    state.busy.add(sessionID);
  } else if (event.type === "session.execution.failed" || event.type === "session.execution.interrupted") {
    state.busy.delete(sessionID);
  } else if (event.type === "session.execution.succeeded") {
    state.busy.delete(sessionID);
    schedule(ctx, state, sessionID);
  }
}

async function listen(ctx, state) {
  try {
    for await (const event of ctx.event.subscribe({ signal: state.signal })) handle(ctx, state, event);
  } catch {
    if (!state.signal.aborted) console.error("wheypoint-idle: event stream ended");
  }
}

export default {
  id: "dotfiles.wheypoint-idle",
  setup(ctx) {
    const controller = new AbortController();
    const state = { consumed: new Map(), pending: new Map(), failedBeforeTurn: new Set(), busy: new Set(), signal: controller.signal };
    void listen(ctx, state);
    return () => controller.abort();
  },
};

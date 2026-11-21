/* walk.js — call walk: entry points first, public calls depth first, private helpers folded. Data is never HTML. */
(() => {
  "use strict";
  const doc = JSON.parse(document.getElementById("architecture-data").textContent);
  const walk = doc.walk;
  const root = document.getElementById("walk");
  const toggle = document.getElementById("walk-toggle");
  const workbench = document.querySelector(".workbench");
  if (!root || !toggle) return;
  if (!walk || !walk.entries || !walk.entries.length) { toggle.hidden = true; return; }
  const N = walk.nodes;
  const MARK = {added: "+", signature: "●", body: "◐", "": "○"};
  const CHANGE = {added: "new", signature: "signature changed", body: "body changed", "": "unchanged"};
  const files = doc.snapshots?.head?.files || {};
  const mapIds = new Set((doc.snapshots?.head?.nodes || []).map(node => node.id));
  const narrow = typeof matchMedia === "function" && matchMedia("(max-width: 850px)").matches;
  const state = {on: false, entry: null, sel: null, open: new Set(), whole: false, unitOpen: false, quietOpen: false, more: false, navOpen: !narrow};

  function element(tag, className, label) {
    const result = document.createElement(tag);
    if (className) result.className = className;
    if (label !== undefined) result.textContent = label;
    return result;
  }
  function button(label, action, className) {
    const result = element("button", className, label);
    result.type = "button";
    result.addEventListener("click", action);
    return result;
  }
  const textCache = new Map();
  function lines(path) {
    if (!textCache.has(path)) {
      const text = files[path]?.text;
      textCache.set(path, typeof text === "string" ? text.split("\n") : []);
    }
    return textCache.get(path);
  }
  const addedCache = new Map();
  function added(path) {
    if (!addedCache.has(path)) addedCache.set(path, new Set(walk.added?.[path] || []));
    return addedCache.get(path);
  }
  function tagOf(node, line) {
    if (line <= node.sigEnd) return "s";
    if (node.doc && line >= node.doc[0] && line <= node.doc[1]) return "d";
    return "b";
  }
  function bodyLines(node) {
    const source = lines(node.path);
    let count = 0;
    for (let line = node.line; line <= node.end; line++) if (tagOf(node, line) === "b" && (source[line - 1] || "").trim()) count++;
    return count;
  }
  function short(node) { return node.kind === "entry" ? node.label : node.qual; }

  // Public callees, found through private helpers, in call order.
  const calleeMemo = new Map();
  function publicCallees(id) {
    if (calleeMemo.has(id)) return calleeMemo.get(id);
    const found = [], seen = new Set([id]);
    const visit = (nodeId, via) => {
      for (const call of N[nodeId].calls) {
        const target = N[call.to];
        if (!target || target.kind === "test" || seen.has(call.to)) continue;
        seen.add(call.to);
        if (target.public) found.push({id: call.to, line: call.line, how: call.how, via});
        else visit(call.to, via.concat(target.qual.split(".").pop()));
      }
    };
    visit(id, []);
    for (const impl of N[id].overrides || []) {
      if (N[impl] && !seen.has(impl)) { seen.add(impl); found.push({id: impl, line: N[id].line, how: "impl", via: []}); }
    }
    calleeMemo.set(id, found);
    return found;
  }
  // Changed code below a node, through every call.
  const reachMemo = new Map();
  function reach(id) {
    if (reachMemo.has(id)) return reachMemo.get(id);
    const found = new Set(), seen = new Set([id]), stack = [id];
    while (stack.length) {
      const current = N[stack.pop()];
      for (const next of [...current.calls.map(call => call.to), ...(current.overrides || [])]) {
        if (seen.has(next) || !N[next] || N[next].kind === "test") continue;
        seen.add(next); stack.push(next);
        if (N[next].change) found.add(next);
      }
    }
    reachMemo.set(id, found);
    return found;
  }
  // A public function with a changed private helper is a step too: the helper shows folded inside it.
  const helperMemo = new Map();
  function helperChange(id) {
    if (helperMemo.has(id)) return helperMemo.get(id);
    helperMemo.set(id, false);
    const found = N[id].calls.some(call => {
      const target = N[call.to];
      return target && !target.public && target.kind !== "test" && (Boolean(target.change) || helperChange(call.to));
    });
    helperMemo.set(id, found);
    return found;
  }
  const stepWorthy = id => Boolean(N[id].change) || (N[id].kind !== "test" && helperChange(id));
  // Depth first from the entry, in call order; only changed steps join the order.
  const orderMemo = new Map();
  function walkOrder(entry) {
    if (orderMemo.has(entry)) return orderMemo.get(entry);
    const order = [], parent = new Map(), seen = new Set();
    const visit = (id, depth) => {
      seen.add(id);
      if (stepWorthy(id) || id === entry) order.push({id, depth});
      if (depth > 200) return;
      for (const callee of publicCallees(id)) {
        if (!seen.has(callee.id)) { parent.set(callee.id, id); visit(callee.id, depth + 1); }
      }
    };
    visit(entry, 0);
    const result = {order, parent, seen, steps: order.filter(item => stepWorthy(item.id)).length};
    orderMemo.set(entry, result);
    return result;
  }

  const entries = walk.entries.filter(entry => N[entry.id]).map(entry => ({...entry, steps: walkOrder(entry.id).steps}));
  const ranked = entries.filter(entry => !entry.orphan && entry.steps)
    .sort((a, b) => b.steps - a.steps || a.label.localeCompare(b.label));
  const orphans = entries.filter(entry => entry.orphan);
  const quiet = entries.filter(entry => !entry.orphan && !entry.steps);

  function setMode(on) {
    state.on = on;
    root.hidden = !on;
    if (workbench) workbench.hidden = on;
    for (const id of ["back", "compare"]) { const control = document.getElementById(id); if (control) control.hidden = on; }
    toggle.setAttribute("aria-pressed", String(on));
    toggle.textContent = on ? "Subsystem map" : "Call walk";
    if (on) render();
  }
  function locate(id) {
    if (state.entry && walkOrder(state.entry).seen.has(id)) return state.entry;
    return [...ranked, ...orphans, ...quiet].find(entry => walkOrder(entry.id).seen.has(id))?.id || state.entry;
  }
  function select(id, push = true) {
    if (!N[id]) return;
    state.entry = entries.some(entry => entry.id === id) ? id : locate(id);
    state.sel = id; state.whole = false; state.unitOpen = false; state.quietOpen = false;
    if (narrow) state.navOpen = false;
    if (push) { try { history.pushState(null, "", "#walk:" + encodeURIComponent(id)); } catch (error) { /* file URLs may refuse history */ } }
    render();
    root.querySelector(".walk-card")?.scrollIntoView?.({block: "nearest"});
  }

  function entryList(target, list, label) {
    if (!list.length) return;
    target.append(element("p", "eyebrow", label));
    for (const entry of list) {
      const node = N[entry.id];
      const item = button("", () => select(entry.id), "walk-entry");
      item.setAttribute("aria-current", String(entry.id === state.entry));
      item.append(element("span", "walk-entry-name", MARK[node.change] + " " + entry.label));
      item.append(element("small", "", entry.steps ? `${entry.steps} changed step${entry.steps === 1 ? "" : "s"}` : entry.path));
      item.title = entry.path + ":" + node.line;
      target.append(item);
    }
  }

  function codeRows(container, nodeId, depth, key, counters) {
    const node = N[nodeId], source = lines(node.path), plus = added(node.path);
    const callsAt = new Map();
    for (const call of node.calls) {
      const target = N[call.to];
      if (!target || target.kind === "test") continue;
      if (!callsAt.has(call.line)) callsAt.set(call.line, []);
      const list = callsAt.get(call.line);
      if (!list.some(item => item.to === call.to)) list.push(call);
    }
    const near = line => { for (let delta = -2; delta <= 2; delta++) if (plus.has(line + delta)) return true; return false; };
    const whole = state.whole && depth === 0;
    const block = element("div", depth ? "walk-block nested" : "walk-block");
    if (depth) block.setAttribute("aria-label", "private helper " + node.qual);
    let run = 0, docSeen = false;
    const flush = () => {
      if (!run) return;
      block.append(element("div", "walk-fold", `⋯ ${run} unchanged line${run === 1 ? "" : "s"}`));
      run = 0;
    };
    for (let line = node.line; line <= node.end; line++) {
      const text = source[line - 1] ?? "";
      const tag = tagOf(node, line), blank = !text.trim(), isAdded = plus.has(line);
      if (depth === 0 && !blank) counters.total++;
      let keep;
      if (whole || tag === "s") keep = true;
      else if (tag === "d") { keep = !docSeen; docSeen = true; }
      else keep = !blank && (near(line) || callsAt.has(line));
      if (!keep) { if (!blank) run++; continue; }
      flush();
      if (depth === 0 && !blank) counters.shown++;
      const row = element("div", "walk-line" + (isAdded ? " added" : "") + (tag === "s" ? " sig" : "") + (tag === "b" && !isAdded ? " quiet" : ""));
      row.dataset.line = String(line);
      row.append(element("span", "walk-num", String(line)), element("span", "walk-mark", isAdded ? "+" : ""), element("span", "walk-text", text));
      block.append(row);
      const here = callsAt.get(line);
      if (!here) continue;
      const chips = element("div", "walk-chips"), opened = [];
      for (const call of here) {
        const target = N[call.to];
        if (target.public) {
          const dynamic = call.how === "dynamic";
          const label = `${dynamic ? "⇢" : "→"} ${short(target)}${dynamic ? ` · ${(target.overrides || []).length} impls` : ""} ${MARK[target.change]}`;
          const chip = button(label, () => select(target.id), "walk-chip" + (target.change ? " changed" : ""));
          chip.title = `${target.path} · ${target.sig}`;
          chips.append(chip);
          continue;
        }
        const childKey = key + ">" + target.id;
        const isOpen = state.open.has(childKey) && depth < 3 && !key.split(">").includes(target.id);
        const size = bodyLines(target);
        counters.helpers++;
        const chip = button(`${isOpen ? "▾" : "▸"} ${target.qual.split(".").pop()} · ${size} line${size === 1 ? "" : "s"}${target.change ? " " + MARK[target.change] : ""}`,
          () => { if (state.open.has(childKey)) state.open.delete(childKey); else state.open.add(childKey); render(); },
          "walk-chip helper" + (target.change ? " changed" : ""));
        chip.setAttribute("aria-expanded", String(isOpen));
        chip.title = "private helper · " + target.sig;
        chips.append(chip);
        if (isOpen) opened.push([target.id, childKey]);
      }
      block.append(chips);
      for (const [childId, childKey] of opened) codeRows(block, childId, depth + 1, childKey, counters);
    }
    flush();
    container.append(block);
  }

  function testsSection(node, visited) {
    const section = element("section", "walk-tests");
    const ids = [], direct = new Set();
    for (const caller of node.callers) {
      const from = N[caller.from];
      if (from?.kind === "test") { direct.add(from.id); if (!ids.includes(from.id)) ids.push(from.id); }
    }
    // A test that drives the entry also exercises every step on its walk.
    if (visited && state.sel !== state.entry) for (const caller of N[state.entry].callers) {
      const from = N[caller.from];
      if (from?.kind === "test" && !ids.includes(from.id)) ids.push(from.id);
    }
    const e2e = ids.filter(id => N[id].e2e), unit = ids.filter(id => !N[id].e2e);
    section.append(element("p", "eyebrow", `TESTS · ${ids.length ? `${e2e.length} end to end · ${unit.length} unit` : "none found"}`));
    for (const id of e2e.slice(0, 4)) {
      const test = N[id], source = lines(test.path), hit = new Set();
      const target = direct.has(id) ? state.sel : state.entry;
      for (const call of test.calls) if (call.to === target) for (let delta = -1; delta <= 1; delta++) hit.add(call.line + delta);
      const card = element("article", "walk-test");
      const head = element("div", "walk-test-head");
      head.append(button(test.qual, () => select(id), "walk-link"), element("small", "", `${test.path}:${test.line} · ${direct.has(id) ? "calls it directly" : "drives " + short(N[state.entry])} ${MARK[test.change]}`));
      card.append(head);
      const pre = element("div", "walk-code compact");
      let last = 0;
      for (let line = test.line; line <= test.end; line++) {
        const text = source[line - 1] ?? "";
        if (!(line <= test.sigEnd || hit.has(line)) || !text.trim()) continue;
        if (last && line > last + 1) pre.append(element("div", "walk-fold", `⋯ ${line - last - 1} line${line - last - 1 === 1 ? "" : "s"}`));
        last = line;
        const row = element("div", "walk-line" + (added(test.path).has(line) ? " added" : "") + (line <= test.sigEnd ? " sig" : " quiet"));
        row.append(element("span", "walk-num", String(line)), element("span", "walk-mark", ""), element("span", "walk-text", text));
        pre.append(row);
      }
      card.append(pre);
      section.append(card);
    }
    if (e2e.length > 4) section.append(element("p", "muted", `+ ${e2e.length - 4} more end-to-end tests: ${e2e.slice(4).map(id => N[id].qual).join(", ")}`));
    if (unit.length) {
      const changed = unit.filter(id => N[id].change).length;
      const fold = button(`${state.unitOpen ? "▾" : "▸"} ${unit.length} unit test${unit.length === 1 ? "" : "s"}${changed ? ` · ${changed} new or changed` : ""}`,
        () => { state.unitOpen = !state.unitOpen; render(); }, "walk-toggle");
      fold.setAttribute("aria-expanded", String(state.unitOpen));
      section.append(fold);
      if (state.unitOpen) {
        const list = element("div", "walk-units");
        for (const id of unit) {
          const item = button(`${MARK[N[id].change]} ${N[id].qual}`, () => select(id), "walk-unit");
          item.append(element("small", "", `${N[id].path}:${N[id].line}`));
          list.append(item);
        }
        section.append(list);
      }
    }
    return section;
  }

  function render() {
    if (!state.on) return;
    const entry = state.entry, sel = N[state.sel] ? state.sel : entry, node = N[sel];
    const {order, parent, seen} = walkOrder(entry);
    const index = order.findIndex(item => item.id === sel);
    root.replaceChildren();
    const layout = element("div", "walk-layout");

    const nav = element("nav", "walk-nav" + (state.navOpen ? " open" : ""));
    nav.setAttribute("aria-label", "Entry points and walk order");
    const navToggle = button(state.navOpen ? "Close ▴" : `Walk ▾ · ${short(N[entry])} · step ${index >= 0 ? index + 1 : "–"} of ${order.length}`,
      () => { state.navOpen = !state.navOpen; render(); }, "walk-nav-toggle");
    navToggle.setAttribute("aria-expanded", String(state.navOpen));
    const navBody = element("div", "walk-nav-body");
    entryList(navBody, ranked, "ENTRY POINTS");
    entryList(navBody, orphans, "CHANGED CODE NO ENTRY REACHES");
    if (quiet.length) {
      const more = button(state.more ? `Hide ${quiet.length} entry points with no changes` : `+ ${quiet.length} entry points with no changes`,
        () => { state.more = !state.more; render(); }, "walk-toggle");
      more.setAttribute("aria-expanded", String(state.more));
      navBody.append(more);
      if (state.more) entryList(navBody, quiet, "NO CHANGES BELOW");
    }
    navBody.append(element("p", "eyebrow", `WALK ORDER · ${walkOrder(entry).steps} changed`));
    const list = element("ol", "walk-order");
    order.forEach((item, position) => {
      const step = N[item.id];
      const row = element("li");
      const link = button("", () => select(item.id), "walk-step");
      link.style.setProperty("--depth", String(Math.min(item.depth, 6)));
      link.setAttribute("aria-current", String(item.id === sel));
      link.append(element("span", "walk-step-num", String(position + 1)), element("span", "", `${MARK[step.change]} ${short(step)}`));
      link.title = `${step.path} · ${step.sig}`;
      row.append(link); list.append(row);
    });
    navBody.append(list);
    nav.append(navToggle, navBody);

    const main = element("div", "walk-main");
    const trail = element("p", "walk-trail");
    const path = [];
    if (seen.has(sel)) { let cursor = sel; while (cursor) { path.unshift(cursor); cursor = parent.get(cursor); } } else path.push(sel);
    path.forEach((id, position) => {
      if (position) trail.append(element("span", "walk-sep", "›"));
      const crumb = button(short(N[id]), () => select(id), "walk-crumb");
      if (id === sel) crumb.setAttribute("aria-current", "true");
      trail.append(crumb);
    });
    main.append(trail);

    const card = element("article", "walk-card");
    const isOrphan = entries.some(item => item.id === entry && item.orphan);
    const kind = sel === entry && !isOrphan && N[sel].kind !== "test" ? "ENTRY POINT" : node.kind === "test" ? "TEST" : node.overrides?.length ? "DISPATCHED METHOD"
      : node.kind === "method" ? (node.public ? "PUBLIC METHOD" : "PRIVATE METHOD") : node.public ? "PUBLIC FUNCTION" : "PRIVATE HELPER";
    const meta = element("div", "walk-card-meta");
    const status = node.change ? `${MARK[node.change]} ${CHANGE[node.change]}` : helperChange(sel) ? "○ unchanged · a private helper changed" : "○ unchanged";
    meta.append(element("span", "eyebrow", kind), element("span", "walk-where", `${node.path}:${node.line}`), element("span", "status " + (node.change ? "changed" : ""), status));
    card.append(meta, element("h2", "walk-sig", node.sig));
    if (node.was) card.append(element("p", "walk-was", "was: " + node.was));
    if (node.summary) card.append(element("p", "walk-doc", node.summary));
    const callers = [...new Set(node.callers.map(caller => caller.from))].filter(id => N[id] && N[id].kind !== "test");
    if (callers.length) {
      const by = element("div", "walk-callers");
      by.append(element("span", "muted", "called by"));
      for (const id of callers.slice(0, 8)) by.append(button(short(N[id]), () => select(id), "walk-crumb"));
      if (callers.length > 8) by.append(element("span", "muted", `+ ${callers.length - 8} more`));
      card.append(by);
    }
    main.append(card);

    const counters = {shown: 0, total: 0, helpers: 0};
    const code = element("div", "walk-code");
    codeRows(code, sel, 0, sel, counters);
    const controls = element("div", "walk-controls");
    const previous = button("← Previous", () => select(order[index - 1].id), "walk-button");
    previous.disabled = index <= 0;
    const nextId = index >= 0 ? order[index + 1]?.id : order[0]?.id;
    const next = button("Next →", () => select(nextId), "walk-button");
    next.disabled = !nextId;
    const whole = button(state.whole ? "Abbreviated" : "Whole function", () => { state.whole = !state.whole; render(); }, "walk-button");
    whole.setAttribute("aria-pressed", String(state.whole));
    controls.append(previous, element("span", "walk-stepcount", index >= 0 ? `step ${index + 1} of ${order.length}` : "off the walk"), next, whole);
    const mapId = sel.replace(/\[[^\]]*\]$/, "");
    if (mapIds.has(mapId)) controls.append(button("Open in map", () => {
      setMode(false);
      document.dispatchEvent(new CustomEvent("architecture:open-node", {detail: {id: mapId, revision: "head"}}));
    }, "walk-button"));
    main.append(controls);
    main.append(element("p", "walk-stats", `showing ${counters.shown} of ${counters.total} lines · ${counters.helpers} private call${counters.helpers === 1 ? "" : "s"} folded`));
    main.append(code);
    main.append(testsSection(node, seen.has(sel)));

    const aside = element("aside", "walk-aside");
    const all = publicCallees(sel);
    const leads = callee => N[callee.id].change || reach(callee.id).size;
    const quietCallees = all.filter(callee => !leads(callee));
    aside.append(element("p", "eyebrow", `CALLS · ${all.length} public`));
    for (const callee of all.filter(leads).concat(state.quietOpen ? quietCallees : [])) {
      const target = N[callee.id];
      const bits = [callee.via.length ? "via " + callee.via.join(" › ") : callee.how === "impl" ? "implements " + node.qual : "L" + callee.line];
      if (callee.how === "dynamic") bits.push("call on an object");
      if (callee.how === "ref") bits.push("passed as a value");
      if (!target.change) { const below = reach(target.id).size; bits.push(below ? `unchanged · leads to ${below} changed` : "unchanged"); }
      const item = button("", () => select(callee.id), "walk-callee" + (target.change ? " changed" : ""));
      item.append(element("span", "walk-callee-name", `${MARK[target.change]} ${short(target)}`));
      if (target.summary) item.append(element("span", "walk-callee-doc", target.summary));
      item.append(element("small", "", bits.join(" · ")));
      aside.append(item);
    }
    if (!all.length) aside.append(element("p", "muted", "No resolved public calls."));
    if (quietCallees.length) {
      const more = button(`${state.quietOpen ? "▾ Hide" : "▸"} ${quietCallees.length} unchanged callee${quietCallees.length === 1 ? "" : "s"} with no changes below`,
        () => { state.quietOpen = !state.quietOpen; render(); }, "walk-toggle");
      more.setAttribute("aria-expanded", String(state.quietOpen));
      aside.append(more);
    }
    const key = element("details", "walk-key");
    key.append(element("summary", "", "Key and limits"));
    for (const text of ["→ public call, or a function passed as a value: opens that function", "⇢ call on an object, resolved by type or method name", "▸ private helper: opens in place",
      "+ new · ● signature changed · ◐ body changed · ○ unchanged", ...(walk.limits || [])]) key.append(element("p", "", text));
    if (walk.unparsed?.length) key.append(element("p", "unknown", `${walk.unparsed.length} Python files did not parse.`));
    aside.append(key);

    layout.append(nav, main, aside);
    root.append(layout);
  }

  toggle.hidden = false;
  toggle.addEventListener("click", () => setMode(!state.on));
  addEventListener("popstate", () => {
    const match = /^#walk:(.+)$/.exec(location.hash);
    if (!match) return;
    let id;
    try { id = decodeURIComponent(match[1]); } catch (error) { return; }
    if (N[id]) { if (!state.on) setMode(true); select(id, false); }
  });
  document.addEventListener("keydown", event => {
    if (!state.on || ["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName) || event.altKey || event.ctrlKey || event.metaKey) return;
    const {order} = walkOrder(state.entry);
    const index = order.findIndex(item => item.id === state.sel);
    const target = event.key === "j" ? (index >= 0 ? order[index + 1] : order[0]) : event.key === "k" ? order[index - 1] : null;
    if (target) { event.preventDefault(); select(target.id); }
  });
  const start = ranked[0] || orphans[0] || quiet[0];
  state.entry = start.id; state.sel = start.id;
  const hash = /^#walk:(.+)$/.exec(location.hash);
  if (hash) { try { const id = decodeURIComponent(hash[1]); if (N[id]) { state.entry = locate(id); state.sel = id; } } catch (error) { /* ignore a malformed hash */ } }
  setMode(Boolean(ranked.length || orphans.length || hash));
})();

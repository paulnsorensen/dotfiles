/* viewer.js — offline architecture review; document data is never HTML. */
(() => {
  "use strict";
  const doc = JSON.parse(document.getElementById("architecture-data").textContent);
  const $ = id => document.getElementById(id);
  const svgNS = "http://www.w3.org/2000/svg";
  const groups = doc.groups || [];
  const snapshots = doc.snapshots || {};
  const changes = doc.changes || {nodes: {}, edges: {}};
  let graphObserver = null;
  const state = {group: null, node: null, revision: "head", compare: false, page: 0, query: "", expanded: new Set(), history: [], edge: null, citation: null, sourceLine: null, graphExpanded: false, indexExpanded: false};

  function element(tag, className, label) {
    const result = document.createElement(tag);
    if (className) result.className = className;
    if (label !== undefined) result.textContent = label;
    return result;
  }
  function svg(tag, attrs = {}) {
    const result = document.createElementNS(svgNS, tag);
    for (const [key, value] of Object.entries(attrs)) result.setAttribute(key, String(value));
    return result;
  }
  function button(label, action, className) {
    const result = element("button", className, label);
    result.type = "button";
    result.addEventListener("click", action);
    return result;
  }
  function labelFor(groupId) {
    return groups.find(group => group.id === groupId)?.label || groupId;
  }
  function snapshot(revision) {
    return snapshots[revision] || {nodes: [], edges: [], unknowns: [], files: {}};
  }
  function nodes(revision) { return snapshot(revision).nodes || []; }
  function edges(revision) {
    const found = snapshot(revision).edges || [];
    return revision === "head" ? found.filter(edge => changes.edges?.[edge.id] !== "removed") : found;
  }
  function changed(id) { return changes.nodes?.[id] || ""; }
  function status(label) {
    const mark = element("span", "status " + label, label);
    return mark;
  }
  function save() {
    state.history.push({group: state.group, node: state.node, revision: state.revision,
      page: state.page, query: state.query, compare: state.compare,
      expanded: new Set(state.expanded), edge: state.edge, citation: state.citation, sourceLine: state.sourceLine, graphExpanded: state.graphExpanded, indexExpanded: state.indexExpanded});
    if (state.history.length > 50) state.history.shift();
  }
  function selectGroup(id, revision = state.revision) {
    save(); state.group = id; state.node = null; state.revision = revision;
    state.edge = null; state.citation = null; state.sourceLine = null; state.graphExpanded = false; state.indexExpanded = false;
    const index = groups.findIndex(group => group.id === id);
    if (index >= 0 && !state.query) state.page = Math.floor(index / 6);
    render();
  }
  function selectNode(id, revision = state.revision, focus = {}) {
    const node = nodes(revision).find(item => item.id === id);
    if (!node) return;
    save(); state.group = node.group; state.node = id; state.revision = revision;
    state.edge = focus.edge || null; state.citation = focus.citation || null;
    state.sourceLine = focus.line || null;
    state.graphExpanded = false;
    const index = groups.findIndex(group => group.id === node.group);
    if (index >= 0 && !state.query) state.page = Math.floor(index / 6);
    render();
    if (focus.line) {
      const side = [...document.querySelectorAll(".revision-side")].find(item => item.dataset.revision === revision);
      side?.querySelector(".source-line.highlighted")?.scrollIntoView?.({block: "center"});
    }
  }
  function matches(group) {
    if (!state.query) return true;
    const query = state.query.toLocaleLowerCase();
    if ((group.label + " " + group.id + " " + group.basis).toLocaleLowerCase().includes(query)) return true;
    return ["head", "base"].some(rev => nodes(rev).some(node =>
      node.group === group.id && (node.id + " " + node.label + " " + node.path).toLocaleLowerCase().includes(query)));
  }
  function mapGroups() { return groups.filter(matches).slice(state.page * 6, (state.page + 1) * 6); }
  function overview() {
    const map = $("map");
    map.replaceChildren();
    const visible = mapGroups();
    const count = visible.length;
    const rows = Math.max(1, Math.ceil(count / 2));
    const width = 800, height = rows * 132 + 28;
    map.setAttribute("viewBox", `0 0 ${width} ${height}`);
    const positions = new Map();
    visible.forEach((group, index) => {
      positions.set(group.id, {x: 30 + (index % 2) * 385, y: 20 + Math.floor(index / 2) * 132});
    });
    const groupByNode = new Map(nodes(state.revision).map(node => [node.id, node.group]));
    const pairs = new Map();
    for (const edge of edges(state.revision)) {
      const from = groupByNode.get(edge.source), to = groupByNode.get(edge.target);
      if (!from || !to || from === to || !positions.has(from) || !positions.has(to)) continue;
      const key = from + "\0" + to;
      if (!pairs.has(key)) pairs.set(key, []);
      pairs.get(key).push(edge);
    }
    const otherRevision = state.revision === "head" ? "base" : "head";
    const otherGroups = new Map(nodes(otherRevision).map(node => [node.id, node.group]));
    const otherPairs = new Map();
    for (const edge of edges(otherRevision)) {
      const key = `${otherGroups.get(edge.source)}\0${otherGroups.get(edge.target)}`;
      if (!otherPairs.has(key)) otherPairs.set(key, new Set());
      otherPairs.get(key).add(edge.id);
    }
    const defs = svg("defs");
    const marker = svg("marker", {id: "map-arrow", viewBox: "0 0 10 10", refX: "9", refY: "5",
      markerWidth: "7", markerHeight: "7", orient: "auto-start-reverse"});
    marker.append(svg("path", {d: "M 0 0 L 10 5 L 0 10 z", class: "map-arrow"}));
    defs.append(marker); map.append(defs);
    for (const [pair, related] of [...pairs.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
      const [from, to] = pair.split("\0"), a = positions.get(from), b = positions.get(to);
      const y1 = a.y + 46, y2 = b.y + 46;
      let d;
      if (a.x === b.x) {
        const right = a.x > width / 2;
        const side = right ? a.x + 355 : a.x;
        const lane = right ? width - 12 : 12;
        d = `M ${side} ${y1} C ${lane} ${y1}, ${lane} ${y1}, ${lane} ${y1 + (y2 > y1 ? 12 : -12)} ` +
          `L ${lane} ${y2} C ${lane} ${y2}, ${lane} ${y2}, ${side} ${y2}`;
      } else {
        const direction = a.x < b.x ? 1 : -1;
        const x1 = a.x + (direction > 0 ? 355 : 0);
        const x2 = b.x + (direction > 0 ? 0 : 355);
        d = `M ${x1} ${y1} C ${x1 + direction * 12} ${y1}, ${x2 - direction * 12} ${y2}, ${x2} ${y2}`;
      }
      const statusSet = new Set(related.map(edge => changes.edges?.[edge.id]).filter(Boolean));
      let kind = statusSet.size === 1 ? [...statusSet][0] : statusSet.size ? "changed" : "";
      const previous = otherPairs.get(pair);
      if (previous?.size && (previous.size !== related.length || related.some(edge => !previous.has(edge.id)))) kind = "changed";
      else if ((kind === "added" || kind === "removed") &&
          related.some(edge => changes.edges?.[edge.id] !== kind)) kind = "changed";
      const line = svg("path", {d, class: "map-link" + (kind ? " " + kind : ""),
        "marker-end": "url(#map-arrow)", "data-from": from, "data-to": to});
      const kinds = [...new Set(related.map(edge => edge.kind))].sort().join(", ");
      const title = svg("title");
      title.textContent = `${labelFor(from)} → ${labelFor(to)} · ${related.length} ${kinds} relationship(s) · ${state.revision}${kind ? " · " + kind : ""}`;
      line.append(title); map.append(line);
    }
    visible.forEach(group => {
      const {x, y} = positions.get(group.id);
      const box = svg("g", {class: "map-node" + (state.group === group.id ? " selected" : "") + (group.changed ? " changed" : ""), role: "button", tabindex: "0", "aria-label": `Open ${group.label} subsystem`, "data-group-id": group.id});
      box.append(svg("rect", {x, y, width: 355, height: 94, rx: 13}));
      const eyebrow = svg("text", {x: x + 18, y: y + 27, class: "map-index"});
      eyebrow.textContent = `0${groups.indexOf(group) + 1}  ·  ${group.changed ? "CHANGED" : "SUBSYSTEM"}`; box.append(eyebrow);
      const name = svg("text", {x: x + 18, y: y + 57, class: "map-name"});
      name.textContent = group.label.length > 30 ? group.label.slice(0, 29) + "…" : group.label; box.append(name);
      const basis = svg("text", {x: x + 18, y: y + 79, class: "map-basis"});
      basis.textContent = group.basis; box.append(basis);
      box.addEventListener("click", () => selectGroup(group.id));
      box.addEventListener("keydown", event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); selectGroup(group.id); } });
      map.append(box);
    });
    if (!count) {
      const empty = svg("text", {x: 32, y: 75, class: "map-basis"});
      empty.textContent = "No matching subsystem. Clear search to return."; map.append(empty);
    }
    const found = groups.filter(matches).length;
    $("overflow").textContent = `Showing ${count ? state.page * 6 + 1 : 0}–${Math.min((state.page + 1) * 6, found)} of ${found} subsystems.`;
    $("groups").replaceChildren();
    const paging = element("div", "paging");
    const prev = button("Previous map", () => {state.page--; render();});
    prev.disabled = state.page === 0;
    const next = button("Next map", () => {state.page++; render();});
    next.disabled = (state.page + 1) * 6 >= found;
    paging.append(prev, next); $("groups").append(paging);
    for (const group of groups.filter(matches)) {
      const item = button(group.label, () => selectGroup(group.id), "group-link");
      item.setAttribute("aria-current", state.group === group.id ? "true" : "false");
      if (group.changed) item.append(status("changed"));
      $("groups").append(item);
    }
    const query = state.query.toLocaleLowerCase();
    if (query) {
      let shown = 0;
      for (const rev of ["head", "base"]) for (const node of nodes(rev)) {
        if (!(node.id + " " + node.label + " " + node.path).toLocaleLowerCase().includes(query)) continue;
        if (shown++ >= 30) continue;
        const item = button(`${node.label} · ${rev}`, () => selectNode(node.id, rev), "entity-link");
        $("groups").append(item);
      }
      if (shown > 30) $("groups").append(element("p", "muted", `${shown - 30} more entities. Refine the search.`));
    }
  }
  function symbolGraph(selected, revision) {
    const box = element("section", "symbol-graph");
    box.setAttribute("aria-label", `One-hop relationships for ${selected.label} at ${revision}`);
    box.append(element("h4", "", "Inbound → selected → outbound"));
    const byId = new Map(nodes(revision).map(node => [node.id, node]));
    const compareEdges = edges(revision).filter(edge => edge.source === selected.id || edge.target === selected.id);
    const order = (a, b) => {
      const rank = edge => changes.edges?.[edge.id] || changed(edge.source === selected.id ? edge.target : edge.source) ? 0 : 1;
      const other = edge => byId.get(edge.source === selected.id ? edge.target : edge.source);
      return rank(a) - rank(b) || (other(a)?.label || "").localeCompare(other(b)?.label || "")
        || a.kind.localeCompare(b.kind) || a.id.localeCompare(b.id);
    };
    const incoming = compareEdges.filter(edge => edge.target === selected.id && edge.source !== selected.id && byId.has(edge.source)).sort(order);
    const outgoing = compareEdges.filter(edge => edge.source === selected.id && edge.target !== selected.id && byId.has(edge.target)).sort(order);
    const self = compareEdges.filter(edge => edge.source === selected.id && edge.target === selected.id).sort(order);
    const limit = state.graphExpanded ? Infinity : 8;
    const shownIncoming = incoming.slice(0, limit), shownOutgoing = outgoing.slice(0, limit);
    const viewport = element("div", "graph-viewport");
    const canvas = element("div", "graph-canvas");
    const wire = svg("svg", {class: "graph-wires", "aria-label": "Directed relationship connectors"});
    const layout = element("div", "graph-layout");
    const left = element("div", "graph-lane"), center = element("div", "graph-center"), right = element("div", "graph-lane");
    left.append(element("p", "graph-lane-label", `Inbound · ${incoming.length}`));
    right.append(element("p", "graph-lane-label", `Outbound · ${outgoing.length}`));
    const focus = button(selected.label, () => selectNode(selected.id, revision), "graph-node focus");
    focus.dataset.graphNode = selected.id;
    focus.setAttribute("aria-label", `Selected ${selected.kind} ${selected.label} at ${revision}`);
    focus.append(element("small", "", selected.kind + " · " + selected.path));
    if (changed(selected.id)) focus.append(status(changed(selected.id)));
    center.append(focus);
    const positions = [];
    function addNeighbor(lane, edge, neighborId, direction) {
      const neighbor = byId.get(neighborId);
      const nodeButton = button(neighbor.label, () => selectNode(neighbor.id, revision), "graph-node");
      nodeButton.dataset.graphNode = neighbor.id;
      nodeButton.setAttribute("aria-label", `Open ${neighbor.kind} ${neighbor.label} at ${revision}`);
      nodeButton.append(element("small", "", neighbor.kind + " · " + neighbor.path));
      nodeButton.append(element("small", "graph-relation-type", `${edge.kind} · ${edge.path}:${edge.line}`));
      const edgeKind = changes.edges?.[edge.id], nodeKind = changed(neighbor.id);
      if (edgeKind) {
        const mark = status(edgeKind);
        mark.textContent = `${edgeKind} reference${edgeKind === nodeKind ? " + symbol" : ""}`;
        nodeButton.append(mark);
      }
      if (nodeKind && nodeKind !== edgeKind) {
        const mark = status(nodeKind);
        mark.textContent = `${nodeKind} symbol`;
        nodeButton.append(mark);
      }
      lane.append(nodeButton);
      const kind = changes.edges?.[edge.id] || "";
      const link = svg("g", {class: "graph-edge" + (kind ? " " + kind : ""), role: "button", tabindex: "0",
        "aria-label": `Open ${revision} ${kind ? kind + " " : ""}${edge.kind} evidence at ${edge.path} line ${edge.line}`});
      link.dataset.graphEdge = edge.id;
      const path = svg("path", {class: "graph-edge-line"});
      const hit = svg("path", {class: "graph-edge-hit"});
      const arrow = svg("polygon", {class: "graph-arrow"});
      link.append(path, hit, arrow);
      const title = svg("title"); title.textContent = `${edge.kind} · ${edge.path}:${edge.line} · ${revision}`; link.append(title);
      const open = () => selectNode(edge.source, revision, {edge: edge.id, line: edge.line});
      link.addEventListener("click", open);
      link.addEventListener("keydown", event => {
        if (event.key === "Enter" || event.key === " ") { event.preventDefault(); open(); }
      });
      wire.append(link);
      positions.push({nodeButton, link, path, hit, arrow, direction});
    }
    for (const edge of shownIncoming) addNeighbor(left, edge, edge.source, "incoming");
    for (const edge of shownOutgoing) addNeighbor(right, edge, edge.target, "outgoing");
    layout.append(left, center, right); canvas.append(wire, layout); viewport.append(canvas); box.append(viewport);
    if (!incoming.length && !outgoing.length && !self.length) box.append(element("p", "empty", "No resolved one-hop relationships at this revision."));
    if (self.length) {
      const loops = element("div", "graph-self");
      loops.append(element("span", "graph-lane-label", `Self calls · ${self.length}`));
      for (const edge of self.slice(0, limit)) {
        const loop = button(`↺ ${edge.kind} · ${edge.path}:${edge.line}`, () =>
          selectNode(edge.source, revision, {edge: edge.id, line: edge.line}), "graph-self-edge");
        loop.dataset.graphEdge = edge.id;
        loop.setAttribute("aria-label", `Open self ${edge.kind} evidence at ${edge.path} line ${edge.line} in ${revision}`);
        if (changes.edges?.[edge.id]) loop.append(status(changes.edges[edge.id]));
        loops.append(loop);
      }
      box.append(loops);
    }
    const hidden = incoming.length - shownIncoming.length + outgoing.length - shownOutgoing.length + self.length - Math.min(self.length, limit);
    if (hidden) box.append(button(`Show all ${incoming.length + outgoing.length + self.length} relationships (${hidden} more)`,
      () => {state.graphExpanded = true; render();}, "graph-more"));
    else if (state.graphExpanded && incoming.length + outgoing.length + self.length > 8)
      box.append(button("Show fewer relationships", () => {state.graphExpanded = false; render();}, "graph-more"));
    function draw() {
      if (!canvas.isConnected) return;
      const bounds = canvas.getBoundingClientRect();
      const width = Math.max(1, canvas.clientWidth), height = Math.max(1, canvas.clientHeight);
      wire.setAttribute("viewBox", `0 0 ${width} ${height}`);
      wire.setAttribute("width", String(width)); wire.setAttribute("height", String(height));
      const a = focus.getBoundingClientRect();
      for (const item of positions) {
        const b = item.nodeButton.getBoundingClientRect();
        const incomingSide = item.direction === "incoming";
        const x1 = (incomingSide ? b.right : a.right) - bounds.left;
        const y1 = (incomingSide ? b.top + b.height / 2 : a.top + a.height / 2) - bounds.top;
        const x2 = (incomingSide ? a.left : b.left) - bounds.left;
        const y2 = (incomingSide ? a.top + a.height / 2 : b.top + b.height / 2) - bounds.top;
        const curve = `M ${x1} ${y1} C ${x1 + 24} ${y1}, ${x2 - 24} ${y2}, ${x2} ${y2}`;
        item.path.setAttribute("d", curve); item.hit.setAttribute("d", curve);
        item.arrow.setAttribute("points", `${x2},${y2} ${x2 - 10},${y2 - 5} ${x2 - 10},${y2 + 5}`);
      }
    }
    requestAnimationFrame(draw);
    if (typeof ResizeObserver !== "undefined") {
      graphObserver = new ResizeObserver(draw);
      graphObserver.observe(canvas);
    }
    return box;
  }
  function describePath(node, revision) {
    const box = element("section", "path-panel");
    box.append(element("h4", "", "Resolved relationships"));
    const byId = new Map(nodes(revision).map(item => [item.id, item]));
    for (const [direction, related] of [
      ["Outgoing", edges(revision).filter(edge => edge.source === node.id)],
      ["Incoming", edges(revision).filter(edge => edge.target === node.id)]
    ]) {
      const section = element("div", "relationship-group");
      section.append(element("h5", "", direction + " · " + related.length));
      if (!related.length) section.append(element("p", "muted", "No resolved " + direction.toLowerCase() + " relationship."));
      for (const edge of related.slice(0, 30)) {
        const other = byId.get(direction === "Outgoing" ? edge.target : edge.source);
        const source = byId.get(edge.source);
        const target = byId.get(edge.target);
        const label = `${edge.kind}: ${source?.label || edge.source} → ${target?.label || edge.target} · ${edge.path}:${edge.line}`;
        const link = button(label, () => selectNode(other.id, revision, {edge: edge.id}), "relationship");
        link.dataset.edgeId = edge.id;
        link.disabled = !other;
        section.append(link);
      }
      if (related.length > 30) section.append(element("p", "muted", `${related.length - 30} more relationships. Search for an endpoint.`));
      box.append(section);
    }
    const unknowns = (snapshot(revision).unknowns || []).filter(item => item.path === node.path);
    if (unknowns.length) {
      const disclosure = element("details", "coverage-detail");
      disclosure.append(element("summary", "", `${unknowns.length} unresolved boundaries in this file`));
      for (const item of unknowns.slice(0, 30)) disclosure.append(element("p", "unknown", `${item.path}:${item.line} · ${item.reason}`));
      box.append(disclosure);
    }
    return box;
  }
  function sourceView(node, revision) {
    const section = element("section", "source-view");
    section.append(element("h4", "", "Source · " + revision));
    const citation = state.citation && doc.annotations?.citations?.[state.citation];
    const selectedEdge = state.edge && edges(revision).find(edge => edge.id === state.edge && edge.source === node.id);
    const citedEdge = citation?.type === "edge" ? edges(revision).find(edge => edge.id === citation.entity) : null;
    const cited = citation?.side === revision && (citation.entity === node.id || citedEdge?.source === node.id) ? citation : null;
    const path = selectedEdge?.path || cited?.path || node.path;
    const file = snapshot(revision).files?.[path];
    const blob = selectedEdge?.blob || cited?.blob || node.blob;
    const focusLine = state.sourceLine || selectedEdge?.line || cited?.line || node.line;
    section.append(element("p", "source-meta", `${path}:${focusLine} · blob ${blob || file?.blob || "unknown"} · lines ${node.line}–${node.end}`));
    if (!file || typeof file.text !== "string" || (file.blob && blob && file.blob !== blob)) {
      section.append(element("p", "empty", "Source is not available for this pinned blob in the artifact."));
      return section;
    }
    const lines = file.text.split("\n");
    if (lines.at(-1) === "") lines.pop();
    const line = Math.min(lines.length, Math.max(1, focusLine));
    const start = Math.max(1, line - 20), end = Math.min(lines.length, line + 20);
    const controls = element("div", "source-controls");
    const previous = button("Earlier lines", () => {state.sourceLine = Math.max(1, line - 40); render();});
    previous.disabled = start === 1;
    const next = button("Later lines", () => {state.sourceLine = Math.min(lines.length, line + 40); render();});
    next.disabled = end === lines.length;
    const jump = element("input");
    jump.type = "number"; jump.min = "1"; jump.max = String(lines.length); jump.value = String(line);
    jump.setAttribute("aria-label", "Source line");
    const go = button("Go to line", () => {
      const requested = Number(jump.value);
      if (Number.isInteger(requested) && requested >= 1 && requested <= lines.length) {
        state.sourceLine = requested; render();
      }
    });
    controls.append(previous, jump, go, next); section.append(controls);
    const pre = element("pre", "source-code");
    const code = element("code");
    for (let index = start; index <= end; index++) {
      const row = element("span", "source-line" + (index === line ? " highlighted" : ""));
      row.dataset.line = String(index);
      if (cited && index === line) row.classList.add("citation-highlight");
      const num = element("span", "line-number", String(index));
      row.append(num, document.createTextNode(lines[index - 1]));
      code.append(row);
    }
    pre.append(code); section.append(pre);
    return section;
  }
  function snapshotDetail(group, revision) {
    const side = element("article", "revision-side");
    side.dataset.revision = revision;
    const snap = snapshot(revision);
    side.append(element("p", "eyebrow", revision.toUpperCase() + " · " + (snap.revision || "unavailable")));
    if (!snapshots[revision]) { side.append(element("p", "empty", "No " + revision + " snapshot.")); return side; }
    const members = nodes(revision).filter(node => node.group === group.id);
    const files = [...new Set(members.map(node => node.path))].sort();
    side.append(element("p", "muted", `${files.length} modules · ${members.length} entities`));
    if (!files.length) side.append(element("p", "empty", "No indexed entities in this subsystem."));
    const coverage = snap.coverage || {};
    const coverageDetail = element("details", "coverage-detail");
    coverageDetail.append(element("summary", "", `Coverage · ${coverage.parsed || 0}/${coverage.files || 0} files parsed · ${coverage.unknowns || 0} unknown boundaries`));
    for (const item of (snap.unknowns || []).slice(0, 50)) {
      coverageDetail.append(element("p", "unknown", `${item.path}:${item.line} · ${item.reason}`));
    }
    const adapters = coverage.adapters || {};
    for (const [extension, adapter] of Object.entries(adapters.supported || {})) {
      coverageDetail.append(element("p", "muted", `${extension} · ${adapter.language} adapter v${adapter.version}`));
    }
    if (adapters.unsupported) {
      coverageDetail.append(element("p", "muted", `Unsupported: ${adapters.unsupported.extensions}; max file size ${adapters.unsupported.max_bytes} bytes.`));
    }
    side.append(coverageDetail);
    const drill = element("section", "module-index");
    drill.append(element("h4", "", "Explore entities"));
    const callIds = new Set(edges(revision).filter(edge => edge.kind === "call").flatMap(edge => [edge.source, edge.target]));
    const ordered = members.filter(node => node.kind !== "file").sort((a, b) =>
      Number(Boolean(changed(b.id))) - Number(Boolean(changed(a.id)))
      || Number(callIds.has(b.id)) - Number(callIds.has(a.id))
      || a.label.localeCompare(b.label) || a.id.localeCompare(b.id));
    const quick = element("div", "module-index-links");
    for (const node of ordered.slice(0, state.indexExpanded ? Infinity : 12)) {
      const entry = button(node.label, () => selectNode(node.id, revision), "entity-link");
      entry.append(element("small", "", node.path));
      if (changed(node.id)) entry.append(status(changed(node.id)));
      quick.append(entry);
    }
    if (!ordered.length) quick.append(element("p", "empty", "No symbol entities in this subsystem."));
    drill.append(quick);
    if (ordered.length > 12) drill.append(button(state.indexExpanded ? "Show fewer entities" : `Show all ${ordered.length} entities`,
      () => {state.indexExpanded = !state.indexExpanded; render();}, "graph-more"));
    side.append(drill);
    const selected = members.find(node => node.id === state.node && revision === state.revision);
    if (selected) {
      const inspected = element("section", "inspection");
      inspected.append(element("h3", "", selected.label));
      inspected.append(element("p", "muted", selected.kind + " · " + (selected.public ? "public" : "internal") + " · " + selected.id));
      const otherRevision = revision === "head" ? "base" : "head";
      if (nodes(otherRevision).some(node => node.id === selected.id)) inspected.append(button(`View ${otherRevision} history for this entity`,
        () => selectNode(selected.id, otherRevision), "history-link"));
      inspected.append(symbolGraph(selected, revision));
      if (state.edge) {
        const edge = edges(revision).find(item => item.id === state.edge);
        if (edge) {
          inspected.append(element("p", "selected-edge", `Selected ${edge.kind} relationship · ${edge.path}:${edge.line} · blob ${edge.blob}`));
          const evidence = button(`Open evidence · ${edge.path}:${edge.line}`, () => selectNode(edge.source, revision, {edge: edge.id, line: edge.line}), "relationship");
          evidence.dataset.edgeEvidenceId = edge.id;
          inspected.append(evidence);
        }
      }
      inspected.append(describePath(selected, revision), sourceView(selected, revision));
      side.append(inspected);
    }
    for (const path of files) {
      const module = element("section", "module");
      const key = revision + ":" + path;
      const isOpen = state.expanded.has(key) || (state.node && state.revision === revision && members.some(node => node.id === state.node && node.path === path));
      const opener = button(path + "  " + (isOpen ? "−" : "+"), () => {
        if (state.expanded.has(key)) state.expanded.delete(key); else state.expanded.add(key);
        render();
      }, "module-toggle");
      opener.setAttribute("aria-expanded", isOpen ? "true" : "false");
      module.append(opener);
      if (isOpen) {
        const list = element("div", "entities");
        const inFile = members.filter(node => node.path === path);
        for (const node of inFile.slice(0, 40)) {
          const item = button(node.label, () => selectNode(node.id, revision), "entity" + (state.node === node.id && state.revision === revision ? " selected" : ""));
          item.append(element("small", "", node.kind + " · " + node.language + " · L" + node.line));
          if (changed(node.id)) item.append(status(changed(node.id)));
          list.append(item);
        }
        if (inFile.length > 40) list.append(element("p", "muted", `${inFile.length - 40} more entities. Use search.`));
        module.append(list);
      }
      side.append(module);
    }
    return side;
  }
  function detail() {
    const target = $("detail"); target.replaceChildren();
    const group = groups.find(item => item.id === state.group);
    if (!group) {
      const title = !doc.base ? "Repository overview" : Object.keys(changes.nodes || {}).length || Object.keys(changes.edges || {}).length ? "Choose a changed area" : "No comparable changes";
      target.append(element("h2", "", title), element("p", "muted", "Select a subsystem on the map or use search."));
      return;
    }
    const heading = element("div", "section-heading");
    const headingText = element("div");
    headingText.append(element("p", "eyebrow", "SELECTED SUBSYSTEM"), element("h2", "", group.label));
    heading.append(headingText, element("p", "muted", "Boundary basis: " + group.basis)); target.append(heading);
    const sides = element("div", state.compare ? "snapshot-grid comparison" : "snapshot-grid");
    if (state.compare && doc.base) sides.append(snapshotDetail(group, "base"));
    sides.append(snapshotDetail(group, state.compare ? "head" : state.revision));
    target.append(sides);
  }
  function annotations() {
    const target = $("annotations"); target.replaceChildren();
    const data = doc.annotations || {};
    if (!data.claims?.length && !data.unknowns?.length && !data.conflicts?.length) return;
    target.append(element("h3", "", "Assessments"));
    for (const claim of data.claims || []) {
      const card = element("div", "assessment");
      card.append(element("strong", "", claim.kind + " · " + claim.claim));
      card.append(element("p", "", claim.reasoning || ""));
      const evidence = element("div", "citations");
      evidence.append(element("small", "", "Evidence:"));
      for (const id of claim.evidence_ids || []) {
        const citation = data.citations?.[id];
        if (!citation) {
          evidence.append(element("span", "unknown", ` Unavailable citation ${id}`));
          continue;
        }
        const label = `${citation.type} · ${citation.path}:${citation.line} · ${citation.side}`;
        const nodeId = citation.type === "edge" ? edges(citation.side).find(edge => edge.id === citation.entity)?.source : citation.entity;
        const link = button(label, () => selectNode(nodeId, citation.side, {citation: id, line: citation.line}), "citation");
        link.dataset.citationId = id;
        link.dataset.citationLine = String(citation.line);
        link.disabled = !nodes(citation.side).some(node => node.id === nodeId);
        evidence.append(link);
      }
      card.append(evidence); target.append(card);
    }
    for (const unknown of data.unknowns || []) target.append(element("p", "unknown", "Unknown: " + unknown));
    for (const conflict of data.conflicts || []) target.append(element("p", "unknown", "Conflict: " + (typeof conflict === "string" ? conflict : JSON.stringify(conflict))));
  }
  function render() {
    graphObserver?.disconnect();
    graphObserver = null;
    $("revisions").textContent = doc.base ? `Base ${doc.base.slice(0, 12)} → Head ${doc.head.slice(0, 12)}` : `Repository · ${doc.head.slice(0, 12)}`;
    $("search").value = state.query;
    $("back").disabled = !state.history.length;
    $("compare").disabled = !doc.base;
    $("compare").setAttribute("aria-pressed", String(state.compare));
    overview(); detail(); annotations();
  }
  function changeTargets() {
    const targets = [];
    for (const [id, kind] of Object.entries(changes.nodes || {})) {
      if (!["added", "removed", "modified"].includes(kind)) continue;
      const revision = kind === "removed" ? "base" : "head";
      const node = nodes(revision).find(item => item.id === id);
      if (node) targets.push({id, group: node.group, revision});
    }
    for (const [id, kind] of Object.entries(changes.edges || {})) {
      if (!["added", "removed", "modified"].includes(kind)) continue;
      const revision = kind === "removed" ? "base" : "head";
      const edge = edges(revision).find(item => item.id === id);
      const node = nodes(revision).find(item => item.id === edge?.source);
      if (node && !targets.some(item => item.id === node.id && item.revision === revision)) {
        targets.push({id: node.id, group: node.group, revision});
      }
    }
    if (!targets.length) for (const group of groups.filter(item => item.changed)) {
      targets.push({id: null, group: group.id, revision: "head"});
    }
    return targets.sort((a, b) =>
      groups.findIndex(item => item.id === a.group) - groups.findIndex(item => item.id === b.group)
      || (a.id || "").localeCompare(b.id || ""));
  }
  function navigateChange(delta) {
    const targets = changeTargets();
    if (!targets.length) return;
    const index = targets.findIndex(item => item.id === state.node && item.group === state.group && item.revision === state.revision);
    const nextIndex = index < 0 ? (delta < 0 ? targets.length - 1 : 0) : (index + delta + targets.length) % targets.length;
    const next = targets[nextIndex];
    if (next.id) selectNode(next.id, next.revision);
    else selectGroup(next.group, next.revision);
  }
  $("back").addEventListener("click", () => {
    const previous = state.history.pop();
    if (!previous) return;
    Object.assign(state, previous);
    render();
  });
  $("compare").addEventListener("click", () => {state.compare = !state.compare; render();});
  document.addEventListener("architecture:open-node", event => selectNode(event.detail?.id, event.detail?.revision || "head"));
  $("previous-change").addEventListener("click", () => navigateChange(-1));
  $("next-change").addEventListener("click", () => navigateChange(1));
  $("search").addEventListener("input", event => {state.query = event.target.value.trim(); state.page = 0; render();});
  document.addEventListener("keydown", event => {
    if (event.key === "/" && !["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName)) {event.preventDefault(); $("search").focus();}
    if (event.key === "Escape" && document.activeElement === $("search")) { $("search").value = ""; state.query = ""; $("search").blur(); render(); }
    if (event.altKey && event.key === "ArrowLeft") {event.preventDefault(); $("back").click();}
  });
  const focus = groups.find(group => group.id === doc.focus);
  if (focus) state.group = focus.id;
  else if (doc.base) {
    const scored = groups.map(group => ({
      group,
      count: nodes("head").filter(node => node.group === group.id && changed(node.id) && node.kind !== "file").length
    })).sort((a, b) => b.count - a.count || a.group.id.localeCompare(b.group.id));
    if (scored[0]?.count) state.group = scored[0].group.id;
    else state.group = groups.find(group => group.changed)?.id || null;
  }
  if (state.group) state.page = Math.floor(groups.findIndex(group => group.id === state.group) / 6);
  render();
})();

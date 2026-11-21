"""Live browser acceptance check for a historical architecture-review artifact.

Run with PYTHONPATH pointing to an installed Playwright package:
    python3 tests/architecture_review/browser_check.py .cheese/arch-preview/index.html
"""
from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path

from playwright.sync_api import sync_playwright

BASE = "cb92ab00b41cb7343db3a0410f2641c0e214339b"
HEAD = "fa73ab4eb6765adbb09498131d7cc08b46cf39a7"
TARGET = "require_compile_targets"
VALIDATORS = ("validate_compile_targets", "validate_harness_field_coverage")


def artifact_data(path: Path) -> dict:
    html = path.read_text(encoding="utf-8")
    match = re.search(
        r'<script id="architecture-data" type="application/json">(.*?)</script>',
        html,
        re.DOTALL,
    )
    assert match, "Real artifact has no embedded architecture data"
    doc = json.loads(match.group(1))
    assert doc["base"] == BASE and doc["head"] == HEAD, "Unexpected revision fixture"
    assert doc["schema"] == 1
    return doc


def node_named(doc: dict, revision: str, name: str) -> dict:
    matches = [
        node for node in doc["snapshots"][revision]["nodes"]
        if node["label"] == name and node["kind"] != "file"
    ]
    assert len(matches) == 1, f"Expected one real {revision} node for {name}; got {len(matches)}"
    return matches[0]


def select_search_result(page, name: str, revision: str) -> None:
    page.keyboard.press("Escape")
    page.keyboard.press("/")
    search = page.locator("#search")
    assert search.evaluate("(element) => document.activeElement === element"), "Slash did not focus search"
    search.fill(name)
    result = page.locator("#groups .entity-link").filter(
        has_text=re.compile(rf"^{re.escape(name)} · {revision}$")
    )
    assert result.count() == 1, f"Missing browser search result: {name} · {revision}"
    result.click()
    assert page.locator("#detail .inspection h3").inner_text() == name


def cited_evidence(doc: dict, citation_id: str) -> dict:
    citations = doc.get("annotations", {}).get("citations", {})
    assert citation_id in citations, f"Annotation cites unknown evidence: {citation_id}"
    citation = citations[citation_id]
    side = citation.get("side")
    assert side in ("head", "base"), f"Citation {citation_id} has an unknown revision"
    snapshot = doc["snapshots"][side]
    path = citation.get("path")
    blob = citation.get("blob")
    source = snapshot["files"].get(path)
    assert source and source.get("blob") == blob, f"Citation {citation_id} has no pinned source"
    line = citation.get("line")
    lines = source["text"].splitlines()
    assert type(line) is int and 1 <= line <= len(lines), f"Citation {citation_id} has no source line"
    assert citation.get("text") == "\n".join(lines[max(0, line - 2):min(len(lines), line + 3)])[:800], (
        f"Citation {citation_id} does not match its source"
    )
    item_type = citation.get("type")
    assert item_type in ("node", "edge"), f"Citation {citation_id} has an unknown entity type"
    items = snapshot["nodes"] if item_type == "node" else snapshot["edges"]
    assert any(
        item["id"] == citation.get("entity") and item["path"] == path
        and item.get("blob") == blob and item.get("line") == line
        for item in items
    ), f"Citation {citation_id} cites a missing or foreign site"
    return citation


def check_symbol_graph(page, doc: dict, target: dict, validators: list[dict], validator_edges: dict) -> None:
    """Follow the graph, not the text-only relationship list."""
    revision = "head"
    snapshot = doc["snapshots"][revision]
    graph = page.locator('#detail .revision-side[data-revision="head"] .symbol-graph')
    assert graph.count() == 1, "Selected head symbol has no graph"
    for validator in validators:
        edge = validator_edges[validator["label"]]
        graph_node = graph.locator(f'[data-graph-node="{validator["id"]}"]')
        graph_edge = graph.locator(f'[data-graph-edge="{edge["id"]}"]')
        assert graph_node.count() == 1, f"Graph omits {validator['label']}"
        assert graph_edge.count() == 1, f"Graph omits call to {validator['label']}"
        assert graph_node.evaluate("node => node.matches('button,[role=button]')"), "Graph node is not keyboard accessible"
        assert graph_edge.evaluate("node => node.matches('button,[role=button]')"), "Graph arrow is not keyboard accessible"
        badges = graph_node.locator(".status").all_text_contents()
        edge_kind = doc["changes"]["edges"].get(edge["id"])
        node_kind = doc["changes"]["nodes"].get(validator["id"])
        if edge_kind and edge_kind == node_kind:
            assert badges == [f"{edge_kind} reference + symbol"], "Duplicate edge and symbol badges"
        elif edge_kind or node_kind:
            expected = ([f"{edge_kind} reference"] if edge_kind else []) + (
                [f"{node_kind} symbol"] if node_kind else []
            )
            assert badges == expected, "Reference and symbol status are not distinct"
        graph_edge.click()
        source = snapshot["files"][edge["path"]]
        assert source["blob"] == edge["blob"], "Graph edge has no pinned caller source"
        meta = page.locator("#detail .source-meta").inner_text()
        assert f'{edge["path"]}:{edge["line"]}' in meta, "Graph arrow lost caller site"
        assert edge["blob"] in meta, "Graph arrow lost caller blob"
        assert page.locator("#detail .revision-side .eyebrow").inner_text().endswith(doc[revision])
        highlighted = page.locator(f'#detail .source-line.highlighted[data-line="{edge["line"]}"]')
        assert highlighted.count() == 1, "Graph arrow did not highlight the caller line"
        source_text = source["text"].splitlines()[edge["line"] - 1]
        shown_text = highlighted.evaluate(
            "node => node.textContent.slice(node.querySelector('.line-number').textContent.length)"
        )
        assert shown_text == source_text, "Graph arrow highlighted the wrong source text"
        page.locator("#back").click()
        assert page.locator("#detail .inspection h3").inner_text() == target["label"]
        graph_node = graph.locator(f'[data-graph-node="{validator["id"]}"]')
        graph_node.focus()
        page.keyboard.press("Enter")
        assert page.locator("#detail .inspection h3").inner_text() == validator["label"]
        page.locator("#back").click()
        assert page.locator("#detail .inspection h3").inner_text() == target["label"]


def check_overview_map(page, doc: dict, revision: str) -> None:
    problems = page.locator("#map").evaluate("""map => {
      const width = map.viewBox.baseVal.width;
      const cards = [...map.querySelectorAll('.map-node rect')];
      const box = node => ({x: +node.getAttribute('x'), y: +node.getAttribute('y'),
        width: +node.getAttribute('width'), height: +node.getAttribute('height')});
      const failures = [];
      for (const card of cards) {
        const rect = box(card);
        if (rect.x < 0 || rect.x + rect.width > width) failures.push('card outside viewBox');
      }
      for (const path of map.querySelectorAll('.map-link')) {
        const from = path.dataset.from, to = path.dataset.to;
        if (!from || !to) { failures.push('link lacks endpoints'); continue; }
        const start = map.querySelector(`.map-node[data-group-id="${from}"] rect`);
        const end = map.querySelector(`.map-node[data-group-id="${to}"] rect`);
        if (!start || !end) { failures.push('link endpoint card missing'); continue; }
        const target = box(end), source = box(start), length = path.getTotalLength();
        const tip = path.getPointAtLength(length), before = path.getPointAtLength(Math.max(0, length - 3));
        if (tip.x < 0 || tip.x > width) failures.push('link outside viewBox');
        const direction = source.x < target.x ? 1 : source.x > target.x ? -1 : source.x < width / 2 ? 1 : -1;
        if ((tip.x - before.x) * direction <= 0) failures.push('arrow does not enter target');
        for (const card of cards) {
          if (card === start || card === end) continue;
          const rect = box(card);
          for (let distance = 1; distance < length - 1; distance += 4) {
            const point = path.getPointAtLength(distance);
            if (point.x > rect.x && point.x < rect.x + rect.width &&
                point.y > rect.y && point.y < rect.y + rect.height) {
              failures.push('link crosses another card'); break;
            }
          }
        }
      }
      return failures;
    }""")
    assert not problems, f"Overview geometry: {problems}"
    visible = set(page.locator("#map .map-node").evaluate_all(
        "nodes => nodes.map(node => node.dataset.groupId)"
    ))
    snapshot = doc["snapshots"][revision]
    by_node = {node["id"]: node["group"] for node in snapshot["nodes"]}
    related = {}
    for edge in snapshot["edges"]:
        if revision == "head" and doc["changes"]["edges"].get(edge["id"]) == "removed":
            continue
        pair = (by_node.get(edge["source"]), by_node.get(edge["target"]))
        if pair[0] in visible and pair[1] in visible and pair[0] != pair[1]:
            related.setdefault(pair, []).append(edge)
    other = doc["snapshots"]["base" if revision == "head" else "head"]
    other_nodes = {node["id"]: node["group"] for node in other["nodes"]}
    other_pairs = {}
    for edge in other["edges"]:
        if revision == "base" and doc["changes"]["edges"].get(edge["id"]) == "removed":
            continue
        pair = (other_nodes.get(edge["source"]), other_nodes.get(edge["target"]))
        other_pairs.setdefault(pair, set()).add(edge["id"])
    shown = {
        (item["from"], item["to"]): item["class"]
        for item in page.locator("#map .map-link").evaluate_all(
            "links => links.map(link => ({from: link.dataset.from, to: link.dataset.to, class: link.getAttribute('class')}))"
        )
    }
    assert shown.keys() == related.keys(), "Overview does not show each visible group dependency"
    for pair, links in related.items():
        statuses = {doc["changes"]["edges"].get(edge["id"]) for edge in links} - {None}
        kind = next(iter(statuses)) if len(statuses) == 1 else "changed" if statuses else ""
        current_ids = {edge["id"] for edge in links}
        previous_ids = other_pairs.get(pair, set())
        if previous_ids and current_ids != previous_ids:
            kind = "changed"
        elif kind in ("added", "removed") and any(
            doc["changes"]["edges"].get(edge["id"]) != kind for edge in links
        ):
            kind = "changed"
        assert (kind in shown[pair].split()) if kind else shown[pair] == "map-link", (
            f"Wrong {revision} status for {pair}: {shown[pair]}"
        )


def check_overview_pages(page, doc: dict, revision: str) -> None:
    previous = page.get_by_role("button", name="Previous map")
    following = page.get_by_role("button", name="Next map")
    while previous.is_enabled():
        previous.click()
    while True:
        check_overview_map(page, doc, revision)
        if not following.is_enabled():
            break
        following.click()
    while previous.is_enabled():
        previous.click()



def check(path: Path) -> None:
    assert path.is_file(), f"HTML artifact does not exist: {path}"
    doc = artifact_data(path)
    target = node_named(doc, "head", TARGET)
    validators = [node_named(doc, "head", name) for name in VALIDATORS]
    edges = doc["snapshots"]["head"]["edges"]
    validator_edges = {}
    for validator in validators:
        matches = [
            edge for edge in edges
            if edge["source"] == target["id"] and edge["target"] == validator["id"]
        ]
        assert len(matches) == 1, f"Expected one resolved head call to {validator['label']}"
        validator_edges[validator["label"]] = matches[0]
    base = doc["snapshots"]["base"]
    labels = [node["label"] for node in base["nodes"] if node["kind"] != "file"]
    historic = next((
        node for node in base["nodes"]
        if node["kind"] != "file" and labels.count(node["label"]) == 1
        and node["path"] in base["files"]
    ), None)
    assert historic, "No unique historic entity has pinned source"
    base_file = base["files"][historic["path"]]
    assert base_file["blob"] == historic["blob"], "Historic source is not pinned"
    base_nodes = {node["id"]: node for node in base["nodes"]}
    removed = next((
        (edge, base_nodes[edge["source"]]) for edge in base["edges"]
        if doc["changes"]["edges"].get(edge["id"]) == "removed"
        and edge["source"] in base_nodes
        and base_nodes[edge["source"]]["kind"] != "file"
        and labels.count(base_nodes[edge["source"]]["label"]) == 1
    ), None)
    assert removed, "Fixture has no unique caller with a removed base call"
    removed_edge, removed_caller = removed
    assert all(edge["id"] != removed_edge["id"] for edge in edges), "Removed call remains in head data"

    errors: list[str] = []
    requests: list[str] = []
    with sync_playwright() as playwright:
        chromium_executable = os.environ.get("CHROMIUM_EXECUTABLE")
        browser = playwright.chromium.launch(
            headless=True,
            **({"executable_path": chromium_executable} if chromium_executable else {}),
        )
        page = browser.new_page(viewport={"width": 1280, "height": 800})
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.on("console", lambda message: errors.append(message.text) if message.type == "error" else None)
        page.on("request", lambda request: requests.append(request.url) if request.url.startswith(("http:", "https:")) else None)
        page.goto(path.resolve().as_uri(), wait_until="load")
        assert page.locator("#map .map-node").count() <= 6, "Opening map exceeds six groups"
        assert page.locator("#map .map-node").count() > 0, "Opening map is empty"
        selected = page.locator("#detail .section-heading h2").inner_text()
        assert selected not in ("Choose a changed area", "No comparable changes"), "Diff has no opening focus"
        assert page.locator("#groups .group-link[aria-current=true] .status.changed").count() == 1, "Opening focus is not changed"
        opening_map = page.locator("#map .map-node").count()
        check_overview_pages(page, doc, "head")

        select_search_result(page, TARGET, "head")
        assert target["path"] in page.locator("#detail .source-meta").inner_text()
        assert page.locator("#detail .path-panel").count() == 1
        for validator in validators:
            edge = validator_edges[validator["label"]]
            relationship = page.locator(f'#detail [data-edge-id="{edge["id"]}"]')
            assert relationship.count() == 1, f"Missing outgoing relationship to {validator['label']}"
            relationship.click()
            assert f'{edge["path"]}:{edge["line"]}' in page.locator("#detail .selected-edge").inner_text()
            assert page.locator("#detail .inspection h3").inner_text() == validator["label"]
            assert validator["path"] in page.locator("#detail .source-meta").inner_text()
            assert validator["label"] in page.locator("#detail .source-code").inner_text()
            page.locator("#back").click()
            assert page.locator("#detail .inspection h3").inner_text() == TARGET, "Back did not restore origin"
            assert page.locator("#map .map-node").count() <= 6, "Back lost bounded map"
        check_symbol_graph(page, doc, target, validators, validator_edges)
        previous = TARGET

        select_search_result(page, historic["label"], "base")
        page.locator("#search").fill("")
        check_overview_pages(page, doc, "base")
        meta = page.locator("#detail .source-meta").inner_text()
        assert historic["blob"] in meta and historic["path"] in meta, "Browser did not show pinned historic source"
        assert page.locator("#detail .revision-side .eyebrow").inner_text().endswith(BASE), "Wrong historic revision"
        page.locator("#back").click()
        assert page.locator("#detail .inspection h3").inner_text() == previous, "Back did not restore prior detail"
        assert page.locator("#map .map-node").count() <= 6, "Back lost bounded map"
        select_search_result(page, removed_caller["label"], "base")
        base_graph = page.locator('#detail .revision-side[data-revision="base"] .symbol-graph')
        base_arrow = base_graph.locator(f'[data-graph-edge="{removed_edge["id"]}"]')
        assert base_arrow.count() == 1, "Removed base call is not drawn"
        assert base_arrow.evaluate(
            "node => (node.textContent + ' ' + node.getAttribute('aria-label') + ' ' + node.getAttribute('class')).toLowerCase().includes('removed')"
        ), "Removed base call has no visible or accessible status"
        head_caller = next((node for node in doc["snapshots"]["head"]["nodes"] if node["id"] == removed_caller["id"]), None)
        if head_caller:
            select_search_result(page, head_caller["label"], "head")
            head_graph = page.locator('#detail .revision-side[data-revision="head"] .symbol-graph')
            assert head_graph.locator(f'[data-graph-edge="{removed_edge["id"]}"]').count() == 0, (
                "Removed base call appears in head graph"
            )
            page.locator("#back").click()
        page.locator("#back").click()
        assert page.locator("#detail .inspection h3").inner_text() == TARGET

        citation_ids = dict.fromkeys(
            citation_id
            for claim in doc.get("annotations", {}).get("claims", [])
            for citation_id in claim["evidence_ids"]
        )
        for citation_id in citation_ids:
            citation = cited_evidence(doc, citation_id)
            link = page.locator(f'#annotations [data-citation-id="{citation_id}"]').first
            assert link.count() == 1, f"Missing clickable citation {citation_id}"
            link.click()
            assert page.locator("#detail .revision-side .eyebrow").inner_text().endswith(
                doc[citation["side"]]
            ), f"Citation {citation_id} opened wrong revision"
            meta = page.locator("#detail .source-meta").inner_text()
            assert f'{citation["path"]}:{citation["line"]}' in meta, "Citation lost source site"
            assert citation["blob"] in meta, "Citation lost pinned blob"
            assert page.locator(
                f'#detail .citation-highlight[data-line="{citation["line"]}"]'
            ).count() == 1, "Citation did not highlight its exact line"
            page.locator("#back").click()
            assert page.locator("#detail .inspection h3").inner_text() == TARGET

        page.set_viewport_size({"width": 375, "height": 812})
        assert page.locator("#search").is_visible() and page.locator("#map").is_visible()
        assert page.locator("#back").is_visible()
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1"), "Narrow viewport has page overflow"
        page.locator("#search").fill(TARGET)
        assert page.locator("#groups .entity-link").count() >= 1, "Narrow search is unusable"
        narrow_arrow = page.locator(
            f'#detail .revision-side[data-revision="head"] .symbol-graph '
            f'[data-graph-edge="{validator_edges[VALIDATORS[0]]["id"]}"]'
        )
        assert narrow_arrow.is_visible(), "Graph arrow is not usable at narrow width"
        narrow_arrow.focus()
        assert narrow_arrow.evaluate("node => document.activeElement === node"), "Narrow graph arrow cannot receive focus"
        page.keyboard.press("Enter")
        edge = validator_edges[VALIDATORS[0]]
        assert f'{edge["path"]}:{edge["line"]}' in page.locator("#detail .source-meta").inner_text(), "Narrow keyboard arrow lost caller site"
        assert page.locator(f'#detail .source-line.highlighted[data-line="{edge["line"]}"]').count() == 1
        assert not errors, f"Browser errors: {errors}"
        assert not requests, f"Navigation made network requests: {requests}"
        print(
            f"PASS browser: opening {opening_map} groups; focus {selected}; "
            f"two validator links and graph arrows; removed base call; "
            f"{len(citation_ids)} citations; historic source; Back; narrow keyboard; "
            "no browser errors or network"
        )
        browser.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("html", type=Path)
    check(parser.parse_args().html)

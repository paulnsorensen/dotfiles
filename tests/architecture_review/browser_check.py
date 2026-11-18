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
        previous = TARGET

        select_search_result(page, historic["label"], "base")
        meta = page.locator("#detail .source-meta").inner_text()
        assert historic["blob"] in meta and historic["path"] in meta, "Browser did not show pinned historic source"
        assert page.locator("#detail .revision-side .eyebrow").inner_text().endswith(BASE), "Wrong historic revision"
        page.locator("#back").click()
        assert page.locator("#detail .inspection h3").inner_text() == previous, "Back did not restore prior detail"
        assert page.locator("#map .map-node").count() <= 6, "Back lost bounded map"

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
        assert not errors, f"Browser errors: {errors}"
        assert not requests, f"Navigation made network requests: {requests}"
        print(f"PASS browser: opening {opening_map} groups; focus {selected}; two validator links; {len(citation_ids)} citations; historic source; Back; narrow viewport; no browser errors or network")
        browser.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("html", type=Path)
    check(parser.parse_args().html)

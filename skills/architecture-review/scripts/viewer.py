"""Render a revision-pinned architecture document as one offline HTML file."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


ASSETS = Path(__file__).resolve().parents[1] / "assets"


def render(doc: dict[str, Any]) -> str:
    """Return a self-contained viewer; never read repository source or call a service."""
    if doc.get("schema") != 1:
        raise ValueError("architecture viewer requires schema 1")
    if not isinstance(doc.get("snapshots"), dict) or "head" not in doc["snapshots"]:
        raise ValueError("architecture viewer requires a head snapshot")
    payload = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
    payload = payload.replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e")
    payload = payload.replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    css = (ASSETS / "viewer.css").read_text(encoding="utf-8")
    js = (ASSETS / "viewer.js").read_text(encoding="utf-8")
    walk_js = (ASSETS / "walk.js").read_text(encoding="utf-8")
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; connect-src 'none'; img-src 'none'; font-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>Architecture review</title><style>{css}</style></head>
<body><div id="architecture-app">
<header class="masthead"><div><p class="eyebrow">LOCAL · REVISION-PINNED</p><h1>Architecture review</h1><p id="revisions" class="muted"></p></div><div class="header-actions"><button id="walk-toggle" type="button" aria-pressed="false" hidden>Call walk</button><button id="back" type="button">← Back</button><button id="compare" type="button" aria-pressed="false">Compare revisions</button></div></header>
<section id="walk" aria-label="Call walk" hidden></section>
<div class="workbench"><aside class="rail" aria-label="Navigation"><label for="search">Find a subsystem or entity</label><input id="search" type="search" aria-label="Search groups and entities" placeholder="Press / to search"><div class="nav-actions"><button id="previous-change" type="button">← Change</button><button id="next-change" type="button">Change →</button></div><p id="overflow" class="muted" role="status"></p><nav id="groups" aria-label="Subsystem groups"></nav><section id="annotations" aria-label="Assessments"></section></aside>
<main><div class="section-heading"><div><p class="eyebrow">SYSTEM MAP</p><h2>Subsystems</h2></div><p class="muted">Select a group. Follow only cited edges.</p></div><div class="map-wrap"><svg id="map" role="img" aria-label="Subsystem relationship diagram"></svg></div><section id="detail" aria-live="polite"></section></main></div>
<script id="architecture-data" type="application/json">{payload}</script><script>{js}</script><script>{walk_js}</script></body></html>'''

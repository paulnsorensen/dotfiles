---
name: roadmap
description: >
  Generate the layered roadmap diagrams from Linear + a sidecar YAML config:
  altitude-1 exec view, altitude-2 workstream swimlanes, and the altitude-3
  dependency-DAG PNG, assembled into an Excalidraw+ presentation and optionally
  published to Notion. Use when the user says "generate the roadmap diagrams",
  "render the roadmap", "update the roadmap deck", or "/roadmap <sidecar-path>".
  Do NOT use for editing arbitrary Excalidraw scenes or managing Linear issues.
model: sonnet
effort: medium
allowed-tools: Bash(node:*), Read, mcp__excalidraw
---

# roadmap

Linear + sidecar YAML in; Excalidraw frames + dependency-DAG PNG out.

The generator is a plain Node CLI (`scripts/`, no install step beyond
`npm ci`/existing `node_modules`); the Excalidraw scene and Notion publishing
happen in this skill layer afterwards.

## Flow

### Step 1: Run the CLI

```bash
node skills/roadmap/scripts/src/cli.js <sidecar-path> --out <dir>   # default ./roadmap-out
```

Environment is optional — the CLI reports what it skipped, never silently:

- `LINEAR_API_KEY` — without it, no Linear fetch; the model is sidecar-only.
- `NOTION_API_KEY` + `notion.page` in the sidecar — without both, no Notion
  publish. Even when wired, the CLI publishes only the heading: it has no
  Excalidraw share link yet (skipped as `notion-bookmark`) and no image-upload
  strategy (skipped as `notion-images`).

Outputs: `altitude-1.json` and `altitude-2.json` (Excalidraw frame JSON,
`{frameName, elements}`) and `altitude-3.png` (the DAG), plus a printed report
of written files and skipped capabilities.

### Step 2: Create the Excalidraw+ scene

Via the Excalidraw MCP:

1. Read the format guides first: `read_presentation_format` (deck structure)
   and `read_diagram_format` (element shapes). Never guess element fields.
2. `create_scene` for the roadmap deck.
3. One slide per altitude: `create_slide`, then `edit_scene_content` inserting
   that altitude's `elements` into the returned frame using its safe area.
4. QA each slide with `take_screenshot`; fix layout drift before moving on.

### Step 3: Attach the DAG PNG

Add `altitude-3.png` to the altitude-3 slide with `add_image` — the PNG is the
rendered artifact; the frame JSONs cover altitudes 1 and 2 only.

### Step 4: Close the Notion gap

If the CLI report shows Notion skips, tell the user exactly what to paste
where: the Excalidraw share link (bookmark) and the altitude PNGs (images)
onto the sidecar's `notion.page`, under the "Excalidraw roadmap" heading the
CLI appended (when publish ran at all).

## Sidecar YAML schema

See `scripts/src/types.js` (`SidecarConfig`) for the authoritative shapes.

```yaml
subject: KIP            # Linear team key; required
buckets: quarters       # quarters | cycles; required
lanes:                  # optional lane overrides (default: Linear initiatives)
  - id: ingest
    title: Ingest       # optional; defaults to id
    initiative: <linear-initiative-id>
items:                  # optional per-project overrides, keyed by project ref
  ingest-api:
    unlocks: ["Self-serve data onboarding"]  # altitude-1 value statements
    altitude: [1, 2]    # views that include this item; default all of 1, 2, 3
    lane: ingest        # lane-id override
    blocks: [dashboards] # fallback dependency edges when Linear lacks them
outcomes:               # altitude-1 cards
  - title: Data platform GA
    horizon: now        # now | next | later
    items: [ingest-api]
notion:                 # optional publish target
  page: <notion-page-id>
```

Validation fails loud on any unknown key or wrong-shaped value, naming the
offending field path.

## Gate

```bash
cd skills/roadmap/scripts && node --test
```

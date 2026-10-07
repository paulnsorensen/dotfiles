---
name: interactive-system-diagram
description: >
  Draws an interactive system-topology diagram that compares proposals in tabs and shows sourced details and tensions on hover.
  Use when the user says "draw the topology", "show me the services and how they talk", "diagram the proposals side by side",
  "where are the tensions between these designs", "make an interactive architecture diagram", or invokes /interactive-system-diagram.
  Do NOT use for a static flowchart, a database schema, a data chart (/dataviz), or a PR walkthrough with before/after Mermaid.
model: opus
effort: high
license: MIT
metadata:
  author: paulnsorensen
---

# interactive-system-diagram

This skill produces one interactive topology widget and a short chat answer that explains how to read it.
The widget shows tiers of services, one tab per proposal, edge states per tab, and numbered tension badges.
Hover or focus on any box, line, or badge to show its sourced detail in an in-flow panel.

## Inputs

The text after the skill name names the system, the decision, and the proposals to compare.
It can also name systems to exclude, such as deprecated or out-of-scope services.
When the text names no proposals, draw one tab for the current state.
Ask for proposals only when the user wants a comparison.

## Flow

1. **Ground the facts.** Collect nodes, edges, proposals, and tensions from code, tickets, and design docs.
   Give each edge a state for every tab, and give each state a source (file:line, doc, ticket, or command output).
   Give each tension a number, the two sources that conflict, and what the conflict blocks.
   Done when every edge state and every tension cites a source, and no excluded system appears.
2. **Cut to the budget.** Keep at most 12 nodes in three or four tiers: callers, entry layer, core, and dependencies.
   Show a few representative examples per tier, not every service.
   Keep at most 4 tabs and 10 tension badges.
   Done when the node list fits the budget.
   Name each cut node in the chat answer, or merge it into a group box.
3. **Pick the surface.** When the host has an inline widget tool (Claude `show_widget`), load its guidance first.
   Read the `diagram` and `interactive` modules completely before the first widget call.
   Otherwise, write one self-contained HTML file in the session folder and open it in a browser.
   Done when the guidance is read, or the HTML file path is chosen.
4. **Build the widget.** Read `references/widget-scaffold.md` and follow its layout rules, data model, and script.
   Encode tier by node colour, edge state by colour plus dash pattern, and tensions as amber `T<n>` badges.
   Done when every `data-k` element has an entry in the data model and every edge has a state for every tab.
5. **Check the geometry.** Run the geometry checklist in `references/widget-scaffold.md`.
   Done when every checklist item passes.
6. **Write the chat answer.** Explain how to read the widget in three bullets or fewer.
   Put the tension table in the chat as Markdown, not in the widget.
   Name the tensions that change today's decision, and give one recommendation.
   Done when the answer leads with the result and every table row cites its sources.

## Output

- One widget (or one HTML file) with tabs, a legend, hover details, and tension badges.
- A chat answer: how to read it, a table of `#`, `Sources in conflict`, and `What it blocks`, then a recommendation.

## What this skill never does

- It never invents an edge state or a tension; an unverified claim says "unverified" in its hover text.
- It never hides content with `display: none` or tabs during streaming; tabs restyle one SVG after the script runs.
- It never uses `position: fixed`, nested scrolling, or prose and tables inside the widget.
- It never draws more than 12 nodes; split into an overview and a detail diagram instead.

## References

- `references/widget-scaffold.md` — read at step 4; the layout rules, data model, script, and geometry checklist.

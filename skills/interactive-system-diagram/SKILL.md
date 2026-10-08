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
Three levels let each reader pick the depth: Overview (Exec), Map (PM), and Detail (Eng).
An answer strip above the diagram gives one answer sentence and the count of open tensions.
Hover or focus on any box, line, or badge to show its detail in an in-flow panel.

## Inputs

The text after the skill name names the system, the decision, and the proposals to compare.
It can also name systems to exclude, such as deprecated or out-of-scope services.
When the text names no proposals, draw one tab for the current state.
Ask for proposals only when the user wants a comparison.

## Flow

1. **Ground the facts.** Collect nodes, edges, proposals, and tensions from code, tickets, and design docs.
   Give each edge a state for every tab.
   Give each edge state a source (file:line, doc, ticket, or command output).
   Give each tension a number, the two sources that conflict, and what the conflict blocks.
   Node sources stay optional; a group edge cites through its member edges.
   Done when every edge state and every tension cites a source, and no excluded system appears.
2. **Cut to the budget.** Keep at most 12 nodes in three or four tiers: callers, entry layer, core, and dependencies.
   Show a few representative examples per tier, not every service.
   Group related nodes in group containers. A container is not a node.
   Keep at most 4 tabs, 10 tension badges, and 3 to 5 walkthrough steps.
   L0 shows at most 5 boxes: the group containers plus the ungrouped nodes.
   Done when the node list fits the budget.
   Name each cut node in the chat answer, or merge it into a group box.
3. **Pick the surface.** When the host has an inline widget tool (Claude `show_widget`), load its guidance first.
   Read the `diagram` and `interactive` modules completely before the first widget call.
   Otherwise, write one self-contained HTML file in the session folder and open it in a browser.
   Done when the guidance is read, or the HTML file path is chosen.
4. **Build the widget.** Read `references/widget-scaffold.md` for layout, data, and theme rules.
   Copy `assets/widget-scaffold.html` as the working artifact and replace its unverified example data with sourced facts.
   Write a plain sentence for every node, edge, group, and tension.
   Write one answer sentence per tab. Write "unverified" in the sentence when the basis is unverified.
   Write 3 to 5 walkthrough steps.
   Add a legend that expands each acronym used in a label.
   Encode tier by node colour, edge state by colour plus dash pattern, and tensions as amber `T<n>` badges.
   Map the host theme variables onto the scaffold's custom properties.
   Done when every `data-k` element has an entry in the data model and every edge has a state for every tab.
5. **Check the plain text.** Run `node scripts/check-widget.mjs <widget.html>` from this skill folder.
   The script runs the widget's inline script as trusted code. Run it only on a file that you wrote.
   Fix each finding line. Run the check again.
   Allow at most 2 rounds of fix and recheck.
   After round 2, report the remaining findings in the chat answer.
   Done when the script exits 0, or the remaining findings are in the answer.
6. **Check the geometry.** Run the geometry checklist in `references/widget-scaffold.md`.
   Done when every checklist item passes.
7. **Write the chat answer.** Explain how to read the widget in three bullets or fewer.
   Put the tension table in the chat as Markdown, not in the widget.
   Name the tensions that change today's decision, and give one recommendation.
   Done when the answer leads with the result and every table row cites its sources.

## Writing rules

Apply these rules to every plain text field, the answer sentence, and the walkthrough captions.

- Put the conclusion first.
- Write one idea per sentence.
- Use active voice.
- Use one term per meaning.
- Use common short words. Expand every jargon term and acronym.
- Write at most 25 words per sentence, and at most 20 words for the answer sentence.
- Write at most 6 sentences per text field.

## Output

- One widget (or one HTML file) with tabs, level buttons, an answer strip, a legend, hover details, and tension badges.
- A chat answer: how to read it, a table of `#`, `Sources in conflict`, and `What it blocks`, then a recommendation.

## What this skill never does

- It never invents an edge state or a tension; an unverified claim says "unverified" in its hover text.
- It never hides content with `display: none` or tabs during streaming; tabs and levels restyle one SVG after the script runs.
- It never uses `position: fixed`, nested scrolling, or tables inside the widget.
- It never puts prose in the widget except the plain text fields, one answer sentence per tab, and the walkthrough captions.
- It never draws more than 12 nodes; it cuts nodes or merges them into a group box instead (step 2).

## References

- `references/widget-scaffold.md` — read at step 4; layout, data, theme, embedding, and geometry rules.
- `assets/widget-scaffold.html` — copy at step 4; complete standalone example with one SVG and local behavior.
- `scripts/check-widget.mjs` — run at step 5; checks word counts, sentence counts, and contrast.

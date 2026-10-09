# Widget scaffold

Read at step 4 of `/interactive-system-diagram`.
Copy [the standalone HTML scaffold](../assets/widget-scaffold.html) into the session folder.
Replace its example topology, labels, states, details, and sources with grounded facts.
The example is generic and unverified. Its edge states demonstrate rendering, not architecture facts.

For an inline widget, read the host guidance first.
Extract the copied document's body content and local style and script into the host's supported widget format.
Keep one SVG. Do not use `display: none` to swap proposal diagrams or levels.

## Levels

Levels and tabs are independent. A tab picks a proposal. A level picks how much of it to show.
The script paints L0 first. The chosen level stays when the reader changes tab.

| Level | Button | Shows | Panel |
|---|---|---|---|
| L0 | Overview · Exec | Group containers (filled), ungrouped nodes, group edges. At most 5 boxes. | Plain sentence and edge chip |
| L1 | Map · PM | Every node, member edge, and badge. Plain subtitles (`sp`). | Plain sentence and edge chip |
| L2 | Detail · Eng | The L1 geometry with technical subtitles (`sx`). | Plain sentence, technical detail, and source |

L0 reuses the L1 geometry. Do not relayout per level.
Hide an element with `opacity: 0`, `pointer-events: none`, `tabindex="-1"`, and `aria-hidden="true"`.
A CSS transition fades the change. `prefers-reduced-motion: reduce` turns the transition off.

## Layout rules

- Use `<svg width="100%" viewBox="0 0 680 H">`. Keep the width at 680 so one unit is one CSS pixel.
- Put the arrow marker in `<defs>` first. Every connector path has the `edge` class and no fill.
- Stack tiers top to bottom: callers (y≈20), entry layer (y≈96), then core and dependencies.
- Draw a group container as `<g class="grp" data-k="g_<id>">` with a rect that surrounds its member nodes.
  Give it two titles. Put a small `.gt` title at the top right, away from connectors. Put a larger `.gtc` title at the rect centre. CSS shows `.gt` at L1 and L2, and `.gtc` at L0. Draw containers before nodes.
  A container is not a node. At L1 and L2 it is a dashed outline with a transparent fill. At L0 it is filled.
- Size each box from its longest label: `width = max(title_chars × 8, subtitle_chars × 7) + 24`. Use the longer of `sp` and `sx`.
- Use two-line boxes 56 px high: title at `y + 19`, subtitle at `y + 38`, both with `dominant-baseline="central"`.
- Give each subtitle an `id="s_<key>"`. The script writes `sp` or `sx` into it.
- Keep at least 20 px between boxes in a row. Keep subtitles to five words or fewer.
- Route a connector that would cross a box as an L-shape: `M x1 y1 L x1 ymid L x2 ymid L x2 y2`.
- Give parallel L-shapes different `ymid` values so that their horizontal segments do not overlap.
- Stop each arrow 2 px before the target edge.
- Colour nodes by tier with `c-*` classes: external actors, the entry layer, and internal services.
- Draw a fence or boundary overlay as a dashed rect with `id="fence"`, then show it per tab from the script.
  It shows at L1 and L2, and hides at L0. Omit the rect when no tab needs a fence; `paint()` skips a missing `#fence`.

## Edge states

Use colour and a dash pattern together, so that colour is never the only cue.

| Key | Meaning | Stroke property | Dash |
|---|---|---|---|
| `v` | verified or done | `--edge-v` | none |
| `p` | partly checked | `--edge-p` | `7 4` |
| `u` | not checked or broken | `--edge-u` | `2 3` |
| `m` | not moved yet or pending | `--edge-m` | `6 3 1 3` |

Add a legend row of short line samples below the diagram.
The legend expands each acronym that a label uses.

## Edge visibility

Every edge names its endpoints `a` and `b`. An endpoint is a node key or a group key.
A group edge has `of`, the list of member edges it summarises. It shows at L0 only.
A group edge takes the worst state of its members: `u`, then `p`, then `m`, then `v`.
A group edge has no source of its own. Its panel lists the member edge titles.
Any other edge shows at a level when both endpoints are visible there.
An edge between two ungrouped nodes shows at every level.

## Hover and focus

- Draw each edge twice: a visible path with `id="v_<key>"`, and a transparent hit path with class `hit` and `data-k="<key>"`.
- Put hit paths after the visible paths and before the badges, so that badges stay on top.
- Give every group, node, hit path, badge, and the tension chip a `data-k`. The script sets `tabindex` and handles `mouseenter` and `focus`.
- Show details in an in-flow panel below the SVG with `aria-live="polite"`. Do not use floating tooltips.
- The panel order is plain sentence, technical detail, source. L0 and L1 show only the plain sentence.
- A group panel lists its member node titles. The tension chip panel lists each open tension and why it matters.
- Esc resets the panel to the tab summary. During a walkthrough, Esc ends it.
- Badges are `<g class="c-amber" data-k="T1">` with a circle of radius 11 and a 12 px label.

## Data and embedding

The asset owns the working data model and script. Change the tables together with matching SVG keys.
The first key in `TABS` is the initial tab.

| Table | Fields |
|---|---|
| `TABS[tab]` | `n` name, `fence`, `a` answer sentence, `x` summary, `s` tab note |
| `G[key]` | `t` title, `p` plain sentence, `members` node keys |
| `N[key]` | `t`, `p`, `x` technical detail, `sp` plain subtitle, `sx` technical subtitle, `g` group, `src` optional |
| `E[key]` | `t`, `p`, `x`, `s` state per tab, `src`, `a`, `b`, `of` for a group edge |
| `T[key]` | `t`, `p`, `x`, `why`, `src`, `tabs` where the tension is open |
| `W` | Steps `{lv, tab?, keys, cap}` |

Every edge needs a state and a source in every configured tab. A group edge (an edge with `of`) needs neither a source nor `s`.
A node without `src` falls back to the tab note `TABS[tab].s`.
`x` and `src` can be a string, or a map from tab to string.
Write 3 to 5 steps in `W`. A step without `tab` uses the tab of the last earlier step that sets one, or else the tab that was active at the start.

Escape source-derived SVG labels as text. Encode `&` as `&amp;` and `<` as `&lt;`.
The detail panel uses `textContent` and creates status chips with DOM methods. Do not use `innerHTML` for labels or details.
Serialize source-derived JavaScript strings as JSON. Then replace each `<` in the serialized text with `\u003c`.
This also prevents a literal `</script>` sequence from ending the script early.

## Theme

Every colour is a CSS custom property. Light values sit in `:root`. Dark values sit in `@media (prefers-color-scheme: dark)`.
`paint()` sets edge strokes through `--edge-v`, `--edge-p`, `--edge-u`, and `--edge-m`.
Do not write a hex colour outside those two blocks.
When the host guidance defines theme variables, map them onto the scaffold's properties in both blocks. Write each mapping as `var(--host-x, #hex)`, because the host page defines `--host-x`, not the file.
`check-widget.mjs` needs 4.5:1 for text pairs and 3:1 for edge strokes against `--svg-bg`, in both schemes.

## Geometry checklist

Check L0 and L1 separately. At L0, no stray label shows from a faded member.

1. The lowest element plus 20 px equals the viewBox height.
2. Every element stays inside x = 0 to 680, with no negative coordinates.
3. Each box is at least as wide as its longest label by the width formula.
4. No connector crosses the interior of a box other than its source and target.
5. No two labels overlap, and no label sits on a line except a badge placed on purpose.
6. Every `data-k` key exists in `G`, `E`, `N`, or `T`, and every non-group `E` entry has a state and a source for every tab.
   Every `G` key, the `tensions` chip key, and every `W` step key exists and is visible at its step level.
7. Text uses only the `t`, `ts`, `th`, `gt`, and `gtc` classes, and sentence case.
8. L0 shows at most 5 boxes, and each group container surrounds only its own members.

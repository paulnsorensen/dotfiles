# Widget scaffold

Read at step 4 of `/interactive-system-diagram`.
Copy [the standalone HTML scaffold](../assets/widget-scaffold.html) into the session folder.
Replace its example topology, labels, states, details, and sources with grounded facts.
The example is generic and unverified. Its edge states demonstrate rendering, not architecture facts.

For an inline widget, read the host guidance first.
Extract the copied document's body content and local style and script into the host's supported widget format.
Keep one SVG. Do not use `display: none` to swap proposal diagrams during streaming.

## Layout rules

- Use `<svg width="100%" viewBox="0 0 680 H">`. Keep the width at 680 so one unit is one CSS pixel.
- Put the arrow marker in `<defs>` first. Every connector path has `fill="none"`.
- Stack tiers top to bottom: callers (y≈20), entry layer (y≈96), a dashed cluster container, then core and dependencies.
- Size each box from its longest label: `width = max(title_chars × 8, subtitle_chars × 7) + 24`.
- Use two-line boxes 56 px high: title at `y + 19`, subtitle at `y + 38`, both with `dominant-baseline="central"`.
- Keep at least 20 px between boxes in a row. Keep subtitles to five words or fewer.
- Route a connector that would cross a box as an L-shape: `M x1 y1 L x1 ymid L x2 ymid L x2 y2`.
- Give parallel L-shapes different `ymid` values so that their horizontal segments do not overlap.
- Stop each arrow 2 px before the target edge.
- Colour nodes by tier with `c-*` classes: gray for external actors, one ramp for the entry layer, one ramp for internal services.
- Draw a fence or boundary overlay as a dashed rect with `id="fence"` and `opacity="0"`, then show it per tab from the script.
  Omit the rect when no tab needs a fence; `paint()` skips a missing `#fence`.

## Edge states

Use colour and a dash pattern together, so that colour is never the only cue.

| Key | Meaning | Stroke | Dash |
|---|---|---|---|
| `v` | verified or done | `#639922` | none |
| `p` | partly checked | `#BA7517` | `7 4` |
| `u` | not checked or broken | `#E24B4A` | `2 3` |
| `m` | not moved yet or pending | `#888780` | `6 3 1 3` |

Add a legend row of short line samples below the diagram.

## Hover and focus

- Draw each edge twice: a visible path with `id="v_<key>"`, and a transparent hit path with `stroke-width="14"` and `data-k="<key>"`.
- Put hit paths after the visible paths and before the badges, so that badges stay on top.
- Give every node group, hit path, and badge a `data-k`. The script adds `tabindex="0"` and handles `mouseenter` and `focus`.
- Show details in an in-flow panel below the SVG with `aria-live="polite"`. Do not use floating tooltips.
- Badges are `<g class="c-amber" data-k="T1">` with a circle of radius 11 and a 12 px label.

## Data and embedding

The asset owns the working data model and script. Change `TABS`, `E`, `N`, and `T` together with matching SVG keys.
The first key in `TABS` is the initial tab. Every edge needs a state and a source in every configured tab.
`E[k].x` can be a string when its detail is the same in every tab.
When a node subtitle changes by tab, store its values in `TABS` and update its text in `paint()`.

Escape source-derived SVG labels as text. Encode `&` as `&amp;` and `<` as `&lt;`.
The detail panel uses `textContent` and creates status chips with DOM methods. Do not use `innerHTML` for labels or details.
Serialize source-derived JavaScript strings as JSON. Then replace each `<` in the serialized text with `\u003c`.
This also prevents a literal `</script>` sequence from ending the script early.

## Geometry checklist

1. The lowest element plus 20 px equals the viewBox height.
2. Every element stays inside x = 0 to 680, with no negative coordinates.
3. Each box is at least as wide as its longest label by the width formula.
4. No connector crosses the interior of a box other than its source and target.
5. No two labels overlap, and no label sits on a line except a badge placed on purpose.
6. Every `data-k` key exists in `E`, `N`, or `T`, and every `E` entry has a state for every tab.
7. Text uses only the `t`, `ts`, and `th` classes, and sentence case.

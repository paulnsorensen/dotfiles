# Widget scaffold

Read at step 4 of `/interactive-system-diagram`.
The scaffold comes from a staging-topology diagram that compared three authentication proposals.

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
- Draw a fence or boundary overlay as a dashed rect with `opacity="0"`, then show it per tab from the script.

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

## Data model

```js
const TABS = { today: { n: 'Today', fence: 0, x: 'Summary of this tab.', s: 'Sources.' } };
const E = { e_a_b: { t: 'A → B', s: { today: 'u', A: 'v' }, x: { today: 'Why it is unchecked.', A: 'What changes.' } } };
const N = { a: ['Node title', 'What it is and how it authenticates.'] };
const T = { T1: ['T1 · Source X vs source Y', 'The clash in two sentences.', 'What it blocks.'] };
```

- `E[k].x` is a string when the text is the same in every tab.
- When a node subtitle changes per tab, store it in `TABS` and set it in `paint()`.

## Script

```html
<script>
const S={v:{c:'#639922',d:'none',l:'Verified',bg:'var(--bg-success)',fg:'var(--text-success)'},p:{c:'#BA7517',d:'7 4',l:'Partly checked',bg:'var(--bg-warning)',fg:'var(--text-warning)'},u:{c:'#E24B4A',d:'2 3',l:'Not checked',bg:'var(--bg-danger)',fg:'var(--text-danger)'},m:{c:'#888780',d:'6 3 1 3',l:'Not moved yet',bg:'var(--surface-1)',fg:'var(--text-secondary)'}};
let tab='today';
const ph=document.getElementById('ph'),pb=document.getElementById('pb'),psrc=document.getElementById('ps');
function chip(st){const s=S[st];return '<span class="chip" style="background:'+s.bg+';color:'+s.fg+'">'+s.l+'</span>';}
function paint(){for(const k in E){const st=E[k].s[tab],el=document.getElementById('v_'+k);el.setAttribute('stroke',S[st].c);el.setAttribute('stroke-dasharray',S[st].d);}
 document.getElementById('fence').setAttribute('opacity',TABS[tab].fence?'1':'0');
 document.querySelectorAll('.tabs button').forEach(b=>b.setAttribute('aria-selected',b.dataset.tab===tab?'true':'false'));
 ph.textContent=TABS[tab].n;pb.textContent=TABS[tab].x;psrc.textContent=TABS[tab].s;}
function show(k){if(E[k]){const e=E[k];ph.innerHTML=e.t+' '+chip(e.s[tab]);pb.textContent=typeof e.x==='string'?e.x:e.x[tab];return;}
 if(T[k]){ph.textContent=T[k][0];pb.textContent=T[k][1];psrc.textContent='Why it matters: '+T[k][2];return;}
 if(N[k]){ph.textContent=N[k][0];pb.textContent=N[k][1];}}
document.querySelectorAll('[data-k]').forEach(el=>{el.setAttribute('tabindex','0');el.addEventListener('mouseenter',()=>show(el.dataset.k));el.addEventListener('focus',()=>show(el.dataset.k));});
document.querySelectorAll('.tabs button').forEach(b=>b.addEventListener('click',()=>{tab=b.dataset.tab;paint();}));
paint();
</script>
```

The tab bar is a row of `<button role="tab" data-tab="…">` elements above the SVG.
The selected tab uses `background: var(--bg-accent)` and `color: var(--text-accent)`.
The first element of the widget is a visually hidden `<h2 class="sr-only">` with a one-sentence summary.

## Geometry checklist

1. The lowest element plus 20 px equals the viewBox height.
2. Every element stays inside x = 0 to 680, with no negative coordinates.
3. Each box is at least as wide as its longest label by the width formula.
4. No connector crosses the interior of a box other than its source and target.
5. No two labels overlap, and no label sits on a line except a badge placed on purpose.
6. Every `data-k` key exists in `E`, `N`, or `T`, and every `E` entry has a state for every tab.
7. Text uses only the `t`, `ts`, and `th` classes, and sentence case.

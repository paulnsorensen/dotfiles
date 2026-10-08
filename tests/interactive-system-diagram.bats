#!/usr/bin/env bats

load test_helper

load interactive-system-diagram

@test "widget scaffold is a standalone document with one SVG and local behavior" {
    [[ -f "$ASSET" ]]
    run node - "$ASSET" <<'NODE'
const fs = require('fs');
const assert = require('assert');
const html = fs.readFileSync(process.argv[2], 'utf8');
assert.match(html, /<!doctype html>/i);
for (const tag of ['html', 'head', 'body', 'style', 'script', 'svg']) {
  assert.match(html, new RegExp('<' + tag + '\\b', 'i'));
}
assert.equal((html.match(/<svg\b/g) || []).length, 1);
assert.equal((html.match(/<script\b/g) || []).length, 1);
assert.doesNotMatch(html, /<(?:script|link)\b[^>]*(?:src|href)=/i);
for (const id of ['ph', 'pb', 'px', 'pm', 'ps', 'fence', 'ans', 'tc', 'walk', 'next', 'back',
  'v_e_caller_gateway', 'v_e_auth_billing', 'v_e_g_entry_core']) {
  assert.match(html, new RegExp('id="' + id + '"'));
}
for (const key of ['caller', 'gateway', 'orders', 'g_entry', 'g_core', 'e_gateway_orders', 'e_g_entry_core', 'T1', 'tensions']) {
  assert.match(html, new RegExp('data-k="' + key + '"'));
}
assert.match(html, /role="tablist"/);
assert.match(html, /aria-live="polite"/);
assert.match(html, /--bg-success:/);
assert.match(html, /--text-danger:/);
NODE
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "actual widget script starts with first configured tab and updates detail sources" {
    vm_run <<'NODE'
const env = load();
const {ph, pb, ps} = env.panel();
assert.equal(env.tabEls[0].attrs['aria-selected'], 'true');
assert.equal(env.id('v_e_auth_billing').style.stroke, 'var(--edge-u)');
assert.equal(env.id('fence').style.opacity, '0');
assert.equal(env.keys.caller.attrs.tabindex, '0');
assert.equal(ps.textContent, 'Example note A. Unverified.');
env.level(2);
env.focus('e_auth_billing');
assert.equal(ps.textContent, 'Example edge source A. Unverified.');
assert.equal(ph.children.length, 1);
env.keys.T1.handlers.mouseenter();
assert.match(env.panel().pm.textContent, /Why it matters:/);
env.focus('gateway');
assert.equal(ps.textContent, 'Example note A. Unverified.');
env.tab('B');
assert.equal(env.tabEls[1].attrs['aria-selected'], 'true');
assert.equal(env.id('v_e_auth_billing').style.stroke, 'var(--edge-m)');
assert.equal(env.id('v_e_auth_billing').attrs['stroke-dasharray'], '6 3 1 3');
assert.equal(env.id('fence').style.opacity, '1');
assert.equal(ps.textContent, 'Example note B. Unverified.');
env.focus('e_auth_billing');
assert.equal(ps.textContent, 'Example edge source B. Unverified.');
env.ev("N.gateway.t = '<img src=x onerror=alert(1)>'");
env.focus('gateway');
assert.equal(ph.textContent, '<img src=x onerror=alert(1)>');
assert.equal(ph.children.length, 0);
assert.equal(ps.textContent, 'Example note B. Unverified.');
const noFence = load(['fence']);
assert.equal(noFence.tabEls[0].attrs['aria-selected'], 'true');
NODE
}

@test "AC-1: first paint shows L0 with filled groups and group edges only" {
    vm_run <<'NODE'
const env = load(), m = env.m;
assert.equal(env.ev('lv'), 0);
const boxes = Object.keys(env.keys).filter(k => (m.G[k] || m.N[k]) && shown(env.keys[k]));
const expected = Object.keys(m.G).length + Object.keys(m.N).filter(k => !m.N[k].g).length;
assert.ok(boxes.length >= 1 && boxes.length <= 5, 'visible boxes: ' + boxes);
assert.equal(boxes.length, expected);
for (const k in m.G) {
  assert.equal(env.keys[k].attrs['data-filled'], 'true');
  assert.ok(shown(env.keys[k]));
}
for (const k in m.E) {
  if (m.E[k].of) assert.ok(shown(env.keys[k]) && shown(env.id('v_' + k)), k);
  else assert.ok(hidden(env.keys[k]) && hidden(env.id('v_' + k)), k);
}
for (const k in m.N) if (m.N[k].g) assert.ok(hidden(env.keys[k]), k);
for (const k in m.T) assert.ok(hidden(env.keys[k]), k);
assert.equal(env.id('fence').style.opacity, '0');
assert.equal(env.id('fence').attrs['aria-hidden'], 'true');
NODE
}

@test "AC-2: level buttons set aria-pressed, hide with attributes, and never use display none" {
    vm_run <<'NODE'
const env = load(), m = env.m;
assert.doesNotMatch(html, /display\s*:\s*none/);
const labels = [0, 1, 2].map(n => html.match(new RegExp('data-lv="' + n + '"[^>]*>([^<]*)<'))[1]);
assert.deepEqual(labels, ['Overview · Exec', 'Map · PM', 'Detail · Eng']);
for (const level of [1, 2, 0]) {
  env.level(level);
  env.lvEls.forEach((b, i) => assert.equal(b.attrs['aria-pressed'], i === level ? 'true' : 'false'));
  for (const k in env.keys) {
    const want = expectShown(m, k, level, 'A');
    assert.ok(want ? shown(env.keys[k]) : hidden(env.keys[k]), 'L' + level + ' ' + k);
  }
  for (const k in m.E) {
    const want = expectShown(m, k, level, 'A');
    assert.ok(want ? shown(env.id('v_' + k)) : hidden(env.id('v_' + k)), 'L' + level + ' line ' + k);
  }
}
NODE
}

@test "AC-3: tab switch keeps the level and repaints answer, count, edges, and badges" {
    vm_run <<'NODE'
const env = load(), m = env.m;
env.level(2);
env.tab('B');
assert.equal(env.ev('lv'), 2);
assert.equal(env.lvEls[2].attrs['aria-pressed'], 'true');
assert.equal(env.id('ans').textContent, m.TABS.B.a);
assert.equal(parseInt(env.id('tc').textContent, 10), openTensions(m, 'B').length);
assert.equal(env.id('v_e_auth_billing').style.stroke, 'var(--edge-m)');
assert.ok(shown(env.keys.T2));
env.tab('A');
assert.equal(env.ev('lv'), 2);
assert.equal(env.id('ans').textContent, m.TABS.A.a);
assert.equal(parseInt(env.id('tc').textContent, 10), openTensions(m, 'A').length);
assert.equal(env.id('v_e_auth_billing').style.stroke, 'var(--edge-u)');
const badge = env.keys.T2;
assert.equal(badge.style.opacity, '0');
assert.equal(badge.attrs.tabindex, '-1');
assert.equal(badge.attrs['aria-hidden'], 'true');
assert.ok(shown(env.keys.T1));
NODE
}

@test "AC-4: L2 panel shows plain, technical, chip, and per-tab source" {
    vm_run <<'NODE'
const env = load(), m = env.m;
const {ph, pb, px, ps} = env.panel();
env.level(2);
env.focus('e_gateway_orders');
assert.equal(pb.textContent, m.E.e_gateway_orders.p);
assert.equal(px.textContent, m.E.e_gateway_orders.x.A);
assert.equal(ps.textContent, m.E.e_gateway_orders.src.A);
assert.equal(ph.children.length, 1);
assert.equal(ph.children[0].textContent, m.S.p.l);
env.tab('B');
env.keys.e_gateway_orders.handlers.mouseenter();
assert.equal(px.textContent, m.E.e_gateway_orders.x.B);
assert.equal(ps.textContent, m.E.e_gateway_orders.src.B);
env.focus('T1');
assert.equal(px.textContent, m.T.T1.x);
assert.equal(ps.textContent, m.T.T1.src);
env.focus('orders');
assert.equal(px.textContent, m.N.orders.x);
assert.equal(ps.textContent, m.N.orders.src);
env.focus('billing');
assert.equal(ps.textContent, m.N.billing.src.B);
env.focus('gateway');
assert.equal(px.textContent, m.N.gateway.x);
assert.equal(ps.textContent, m.TABS.B.s);
NODE
}

@test "AC-5: L0 and L1 panel shows only the plain sentence and the edge chip" {
    vm_run <<'NODE'
const env = load(), m = env.m;
const {ph, pb, px, pm, ps} = env.panel();
for (const level of [0, 1]) {
  env.level(level);
  for (const k of ['gateway', 'e_gateway_orders', 'T1']) {
    env.focus(k);
    const entry = m.N[k] || m.E[k] || m.T[k];
    assert.equal(pb.textContent, entry.p, k);
    assert.equal(px.textContent, '', 'L' + level + ' ' + k);
    assert.equal(ps.textContent, '', 'L' + level + ' ' + k);
    assert.equal(pm.textContent, '', 'L' + level + ' ' + k);
    assert.equal(ph.children.length, m.E[k] ? 1 : 0, k);
  }
}
NODE
}

@test "AC-6: answer strip precedes the SVG with a short sentence and the open-tension count" {
    vm_run <<'NODE'
const env = load(), m = env.m;
assert.ok(html.indexOf('id="answer"') !== -1);
assert.ok(html.indexOf('id="answer"') < html.indexOf('<svg'));
assert.ok(html.indexOf('id="ans"') < html.indexOf('<svg'));
assert.ok(html.indexOf('id="tc"') < html.indexOf('<svg'));
for (const level of [0, 1, 2]) {
  env.level(level);
  for (const tab of Object.keys(m.TABS)) {
    env.tab(tab);
    const text = env.id('ans').textContent;
    assert.equal(text, m.TABS[tab].a);
    assert.ok(words(text) <= 20, text);
    assert.equal(parseInt(env.id('tc').textContent, 10), openTensions(m, tab).length);
  }
}
assert.notEqual(openTensions(m, 'A').length, openTensions(m, 'B').length);
NODE
}

@test "AC-7: tension chip lists only tensions open in the current tab" {
    vm_run <<'NODE'
const env = load(), m = env.m;
const {pm} = env.panel();
env.level(1);
env.focus('tensions');
assert.ok(pm.textContent.includes(m.T.T1.t) && pm.textContent.includes(m.T.T1.why));
assert.ok(!pm.textContent.includes(m.T.T2.t) && !pm.textContent.includes(m.T.T2.why));
env.tab('B');
env.keys.tensions.handlers.mouseenter();
for (const k of ['T1', 'T2']) {
  assert.ok(pm.textContent.includes(m.T[k].t) && pm.textContent.includes(m.T[k].why), k);
}
NODE
}

@test "AC-8: walkthrough start applies step 1, dims other elements, and enables Next and Back" {
    vm_run <<'NODE'
const env = load(), m = env.m;
assert.ok(m.W.length >= 3 && m.W.length <= 5);
env.level(2);
env.id('walk').handlers.click();
const step = m.W[0];
assert.equal(env.ev('lv'), step.lv);
assert.equal(env.panel().pb.textContent, step.cap);
assert.equal(env.id('next').disabled, false);
assert.equal(env.id('back').disabled, false);
function dimmed(step, tab) {
  const want = k => !expectShown(m, k, step.lv, tab) ? '0' : step.keys.includes(k) ? '1' : '0.25';
  for (const k in env.keys) assert.equal(env.keys[k].style.opacity, want(k), k);
  for (const k in m.E) assert.equal(env.id('v_' + k).style.opacity, want(k), 'line ' + k);
  return Object.keys(m.E).filter(k => env.id('v_' + k).style.opacity === '0.25').length;
}
dimmed(step, step.tab || 'A');
assert.ok(Object.keys(env.keys).some(k => env.keys[k].style.opacity === '0.25'));
env.id('next').handlers.click();
assert.equal(env.panel().pb.textContent, m.W[1].cap);
assert.ok(dimmed(m.W[1], 'A') > 0, 'a visible edge outside the step keys dims');
env.id('back').handlers.click();
assert.equal(env.panel().pb.textContent, m.W[0].cap);
NODE
}

@test "AC-9: Esc or the last step ends the walkthrough and restores tab and level" {
    vm_run <<'NODE'
const env = load(), m = env.m;
function undimmed() {
  for (const k in env.keys) assert.notEqual(env.keys[k].style.opacity, '0.25', k);
  for (const k in m.E) assert.notEqual(env.id('v_' + k).style.opacity, '0.25', k);
}
env.tab('B');
env.level(1);
env.id('walk').handlers.click();
assert.equal(env.ev('lv'), m.W[0].lv);
env.esc();
assert.equal(env.ev('lv'), 1);
assert.equal(env.ev('tab'), 'B');
assert.equal(env.lvEls[1].attrs['aria-pressed'], 'true');
undimmed();
env.id('walk').handlers.click();
for (let i = 1; i < m.W.length; i++) env.id('next').handlers.click();
assert.equal(env.ev('tab'), m.W[m.W.length - 1].tab || 'B');
assert.notEqual(env.ev('tab'), 'B');
env.id('next').handlers.click();
assert.equal(env.ev('lv'), 1);
assert.equal(env.ev('tab'), 'B');
undimmed();
NODE
}

@test "AC-10: Esc outside the walkthrough resets the panel to the tab summary" {
    vm_run <<'NODE'
const env = load(), m = env.m;
const {ph, pb, px, pm, ps} = env.panel();
env.level(2);
env.focus('gateway');
assert.equal(ph.textContent, 'Gateway');
env.esc();
assert.equal(ph.textContent, m.TABS.A.n);
assert.equal(pb.textContent, m.TABS.A.x);
assert.equal(ps.textContent, m.TABS.A.s);
assert.equal(px.textContent, '');
assert.equal(pm.textContent, '');
NODE
}

@test "AC-11: group edge takes the worst member state and shows no source" {
    vm_run <<'NODE'
const env = load(), m = env.m;
const {ph, pb, px, pm, ps} = env.panel();
const line = env.id('v_e_g_entry_core');
assert.equal(line.style.stroke, 'var(--edge-u)');
assert.equal(line.attrs['stroke-dasharray'], m.S.u.d);
env.focus('e_g_entry_core');
assert.equal(pb.textContent, m.E.e_g_entry_core.p);
assert.equal(ph.children.length, 1);
assert.equal(ph.children[0].textContent, m.S.u.l);
for (const member of m.E.e_g_entry_core.of) assert.ok(pm.textContent.includes(m.E[member].t), member);
assert.equal(ps.textContent, '');
assert.equal(px.textContent, '');
env.tab('B');
assert.equal(line.style.stroke, 'var(--edge-m)');
env.ev("E.e_gateway_orders.s.B = 'p'");
env.tab('B');
assert.equal(line.style.stroke, 'var(--edge-p)');
env.ev("E.e_gateway_orders.s.B = 'v'; E.e_auth_billing.s.B = 'v'");
env.tab('B');
assert.equal(line.style.stroke, 'var(--edge-v)');
NODE
}

@test "AC-12: reduced motion disables the level transition" {
    vm_run <<'NODE'
const list = html.match(/([^{}]+)\{\s*transition\s*:\s*opacity[^}]*\}/);
assert.ok(list, 'transition rule');
const selectors = list[1].trim();
const reduce = html.match(/@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{\s*([^{}]+)\{\s*transition\s*:\s*none/);
assert.ok(reduce, 'reduced-motion rule');
assert.equal(reduce[1].trim(), selectors, 'reduced-motion rule covers the transition selectors');
NODE
}

@test "AC-13: SKILL.md and the reference carry the progressive-disclosure rules" {
    run node - "$SKILL_MD" "$REFERENCE_MD" <<'NODE'
const fs = require('fs');
const assert = require('assert');
const skill = fs.readFileSync(process.argv[2], 'utf8');
const ref = fs.readFileSync(process.argv[3], 'utf8');
assert.match(skill, /at most 5 boxes/i);
assert.match(skill, /at most 20 words/i);
assert.match(skill, /plain sentence for every node, edge, group, and tension/i);
assert.match(skill, /3 to 5 (walkthrough )?steps/i);
assert.match(skill, /expand[s]? each acronym/i);
assert.match(skill, /node sources (stay|are) optional/i);
assert.match(skill, /group edges? (cite|cites) through (their|its) member edges/i);
assert.match(skill, /one answer sentence/i);
assert.match(ref, /endpoints `a` and `b`/);
assert.match(ref, /group edge[^\n]*(no|without)[^\n]*source/i);
assert.match(ref, /3 to 5 steps/i);
assert.match(ref, /legend[^\n]*expand/i);
assert.match(ref, /L0 and L1 separately/);
assert.match(ref, /every `G` key, the `tensions` chip key, and every `W` step key/i);
assert.match(ref, /visible at (its|their) step level/);
NODE
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "AC-14: L1 shows the plain subtitle and L2 shows the technical subtitle" {
    vm_run <<'NODE'
const env = load(), m = env.m;
for (const k in m.N) {
  assert.notEqual(m.N[k].sp, m.N[k].sx, k);
  env.level(1);
  assert.equal(env.id('s_' + k).textContent, m.N[k].sp, k);
  env.level(2);
  assert.equal(env.id('s_' + k).textContent, m.N[k].sx, k);
}
NODE
}

@test "AC-15: walkthrough steps point at real keys that are visible at their level and tab" {
    vm_run <<'NODE'
const env = load(), m = env.m;
assert.ok(m.W.length >= 3 && m.W.length <= 5);
for (const [i, step] of m.W.entries()) {
  assert.ok([0, 1, 2].includes(step.lv), 'step ' + i);
  if (step.tab) assert.ok(step.tab in m.TABS, 'step ' + i);
  const tabs = step.tab ? [step.tab] : Object.keys(m.TABS);
  for (const k of step.keys) {
    assert.ok(m.N[k] || m.E[k] || m.G[k] || m.T[k], 'step ' + i + ' key ' + k);
    for (const tab of tabs) assert.ok(expectShown(m, k, step.lv, tab), 'step ' + i + ' ' + k + ' in ' + tab);
  }
}
NODE
}

@test "AC-16: group container panel lists members and the outline stays dashed and focusable" {
    vm_run <<'NODE'
const env = load(), m = env.m;
const {ph, pb, px, pm, ps} = env.panel();
assert.match(html, /\.grp rect\s*\{[^}]*fill:\s*transparent[^}]*stroke-dasharray/);
assert.match(html, /\.grp\[data-filled="true"\] rect\s*\{[^}]*fill:\s*var\(--grp-fill\)/);
for (const level of [0, 1, 2]) {
  env.level(level);
  for (const k in m.G) {
    env.focus(k);
    assert.equal(ph.textContent, m.G[k].t);
    assert.equal(pb.textContent, m.G[k].p);
    for (const member of m.G[k].members) assert.ok(pm.textContent.includes(m.N[member].t), member);
    assert.equal(ps.textContent, '');
    assert.equal(px.textContent, '');
    assert.equal(env.keys[k].attrs.tabindex, '0', 'L' + level + ' ' + k);
    assert.equal(env.keys[k].attrs['data-filled'], level === 0 ? 'true' : 'false');
  }
}
NODE
}

@test "AC-17: check-widget reports answer, sentence, and count findings" {
    run node "$CHECK" "$ASSET"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ -z "$output" ]]

    fixture "$ANSWER_A" "${ANSWER_A%.}, so please check it now."
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"TABS.A.a [answer-words]"*" → "* ]] || { echo "$output"; return 1; }
    [[ "$(echo "$output" | wc -l)" -eq 1 ]]

    fixture "$ANSWER_A" "${ANSWER_A%.}, so please check it."
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

    fixture "$PLAIN_P" "$(n_words 26)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"caller.p [plain-words]"* ]] || { echo "$output"; return 1; }

    fixture "$PLAIN_P" "$(n_words 25)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

    fixture "$PLAIN_P" "One. Two. Three. Four. Five. Six. Seven."
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"caller.p [sentence-count]"* ]] || { echo "$output"; return 1; }

    fixture "$PLAIN_P" "One. Two. Three. Four. Five. Six."
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

    fixture "Start here. Two example groups" "$(n_words 26) Two example groups"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"W[0] [plain-words]"* ]] || { echo "$output"; return 1; }
}

@test "AC-18: every colour comes from a theme custom property with a dark override" {
    vm_run <<'NODE'
const darkRe = /@media \(prefers-color-scheme: dark\) \{\s*:root \{([^}]*)\}\s*\}/;
const dark = html.match(darkRe);
assert.ok(dark, 'dark block');
const rest = html.replace(darkRe, '');
const light = rest.match(/:root \{([^}]*)\}/);
assert.ok(light, 'light block');
const outside = rest.replace(light[0], '');
assert.doesNotMatch(outside, /#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})(?![-\w])/, 'hex colour outside theme blocks');
assert.doesNotMatch(outside, /\b(?:rgb|rgba|hsl|hsla)\(/);
const plainValue = new Set(['none', 'transparent', 'inherit', 'currentcolor', 'solid', 'dashed', 'dotted', 'double',
  'thin', 'medium', 'thick', 'auto', '!important']);
const cssOnly = outside.slice(0, outside.indexOf('</style>'));
const colourDecl = /(?:^|[;{\s])((?:color|background(?:-color)?|border(?:-(?:top|right|bottom|left))?(?:-color)?|outline(?:-color)?|(?:box|text)-shadow|fill|stroke))\s*:\s*([^;}]+)/g;
for (const [, prop, value] of cssOnly.matchAll(colourDecl)) {
  const named = value.replace(/var\([^)]*\)/g, '').split(/[\s,]+/)
    .filter(t => t && !/^-?[\d.]+(?:px|em|rem|%)?$/.test(t) && !plainValue.has(t.toLowerCase()));
  assert.deepEqual(named, [], prop + ' uses a colour outside the theme: ' + value);
}
const markupOnly = outside.slice(0, outside.indexOf('<script>'));
assert.doesNotMatch(markupOnly, /\b(?:fill|stroke|color|background)\s*[:=]\s*"?(?!var\(|none|transparent|inherit|currentColor)[a-z]+/i);
const names = block => [...block.matchAll(/(--[\w-]+)\s*:/g)].map(m => m[1]);
const lightNames = new Set(names(light[1])), darkNames = new Set(names(dark[1]));
for (const name of ['--bg', '--fg', '--muted', '--svg-bg', '--edge-v', '--edge-p', '--edge-u', '--edge-m']) {
  assert.ok(lightNames.has(name) && darkNames.has(name), name);
}
for (const name of darkNames) assert.ok(lightNames.has(name), 'dark only: ' + name);
for (const m of html.matchAll(/var\((--[\w-]+)\)/g)) assert.ok(lightNames.has(m[1]), 'undefined ' + m[1]);
assert.match(script, /var\(--edge-/);
const env = load();
for (const k in env.m.E) assert.match(env.id('v_' + k).style.stroke, /^var\(--edge-[vpum]\)$/);
NODE
}

@test "AC-19: check-widget reports contrast failures in either colour scheme" {
    fixture "--fg: #ececec" "--fg: #626262"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"dark:--fg/--bg [contrast]"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"light:"* ]]

    fixture "--muted: #595959" "--muted: #8a8a8a"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"light:--muted/--bg [contrast]"* ]] || { echo "$output"; return 1; }

    fixture "--edge-v: #8bc34a" "--edge-v: #2a2f2a"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"dark:--edge-v/--svg-bg [contrast]"* ]] || { echo "$output"; return 1; }

    fixture "--edge-m: #6b6a64;
}" "--edge-m: #e0e0dc;
}"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"light:--edge-m/--svg-bg [contrast]"* ]] || { echo "$output"; return 1; }
}

@test "AC-20: SKILL.md lists the seven STE rules and the two-round check loop" {
    run node - "$SKILL_MD" <<'NODE'
const fs = require('fs');
const assert = require('assert');
const skill = fs.readFileSync(process.argv[2], 'utf8');
for (const rule of [/conclusion first/i, /one idea per sentence/i, /active voice/i, /one term per meaning/i,
  /common short words/i, /at most 25 words per sentence/i, /at most 6 sentences per text field/i]) {
  assert.match(skill, rule);
}
assert.match(skill, /at most 20 words/i);
const check = skill.indexOf('check-widget.mjs');
const geometry = skill.indexOf('Check the geometry');
assert.ok(check !== -1 && geometry !== -1 && check < geometry, 'check-widget runs before the geometry checklist');
assert.match(skill, /at most 2 (fix-and-recheck )?rounds/i);
assert.match(skill, /report[^\n]*remaining findings/i);
NODE
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "AC-21: group edges show only at L0 and other edges follow their endpoints" {
    vm_run <<'NODE'
const env = load(), m = env.m;
for (const level of [0, 1, 2]) {
  env.level(level);
  for (const k in m.E) {
    const want = m.E[k].of ? level === 0 : boxShown(m, m.E[k].a, level) && boxShown(m, m.E[k].b, level);
    assert.equal(shown(env.keys[k]), want, 'L' + level + ' ' + k);
    assert.equal(shown(env.id('v_' + k)), want, 'L' + level + ' line ' + k);
  }
}
env.ev("N.s1 = {t:'S1', p:'x.', x:'x', sp:'x', sx:'x'}; N.s2 = {t:'S2', p:'x.', x:'x', sp:'x', sx:'x'};" +
  "E.ex = {t:'x', p:'x.', x:'x', s:{A:'v', B:'v'}, src:'x', a:'s1', b:'s2'}");
for (const level of [0, 1, 2]) assert.ok(env.ev('isVisible("ex", ' + level + ')'), 'ungrouped edge at L' + level);
env.ev("N.s2.g = 'g_core'");
assert.ok(env.ev('isVisible("ex", 0)') === false && env.ev('isVisible("ex", 1)'));
NODE
}

@test "CURE-1: the reference escape rule names the literal six-character escape text" {
    # shellcheck disable=SC2016  # literal escape text to match, not for expansion
    grep -qF 'with `\u003c`.' "$REFERENCE_MD"
}

@test "CURE-2: per-tab x maps on nodes and tensions resolve at L2" {
    vm_run <<'NODE'
const env = load();
const {px} = env.panel();
env.ev("N.orders.x = {A:'orders-a', B:'orders-b'}; T.T1.x = {A:'t1-a', B:'t1-b'}");
env.level(2);
env.focus('orders');
assert.equal(px.textContent, 'orders-a');
env.focus('T1');
assert.equal(px.textContent, 't1-a');
env.tab('B');
env.keys.orders.handlers.mouseenter();
assert.equal(px.textContent, 'orders-b');
env.keys.T1.handlers.mouseenter();
assert.equal(px.textContent, 't1-b');
NODE
}

@test "CURE-3: Back from a tab step returns to the tab that Next showed on that step" {
    vm_run <<'NODE'
const env = load();
env.ev('delete W[3].tab');
env.id('walk').handlers.click();
assert.equal(env.ev('tab'), 'A');
env.id('next').handlers.click();
env.id('next').handlers.click();
assert.equal(env.ev('tab'), 'B');
env.id('next').handlers.click();
assert.equal(env.ev('tab'), 'B');
env.id('back').handlers.click();
env.id('back').handlers.click();
assert.equal(env.ev('tab'), 'A');
NODE
}

@test "CURE-4: check-widget resolves var() colours and reports every colour it cannot check" {
    fixture "--fg: #ececec" "--fg: var(--host-fg); --host-fg: #626262"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"dark:--fg/--bg [contrast] "*":1, limit 4.5:1"* && "$output" != *unchecked* ]] || { echo "$output"; return 1; }

    fixture "--fg: #ececec" "--fg: red"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"dark:--fg/--bg [contrast] unchecked"* ]] || { echo "$output"; return 1; }

    fixture "@media (prefers-color-scheme: dark)" "@media (prefers-color-scheme: light)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"dark [contrast] no dark block"* ]] || { echo "$output"; return 1; }

    fixture $'  :root {\n    --bg: #15161a; --fg: #ececec' $'  :root, .dark {\n    --bg: #15161a; --fg: #626262'
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"dark:--fg/--bg [contrast] "*":1, limit 4.5:1"* && "$output" != *unchecked* ]] || { echo "$output"; return 1; }
}

@test "CURE-5: check-widget limits microtasks and SKILL.md names it as trusted-code execution" {
    grep -qF "microtaskMode: 'afterEvaluate'" "$CHECK"
    grep -qi 'trusted' "$CHECK"
    grep -qi 'trusted code' "$SKILL_MD"
}

@test "CURE-6: check-widget reads tags with attributes, exits 2 on a missing file, and hints at stubs" {
    fixture '<script>' '<script type="text/javascript">'
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

    fixture '<style>' '<style media="all">'
    fixture_more '--fg: #ececec' '--fg: #626262'
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"dark:--fg/--bg [contrast] "*":1, limit 4.5:1"* && "$output" != *unchecked* ]] || { echo "$output"; return 1; }

    run node "$CHECK" "$BATS_TEST_TMPDIR/missing.html"
    [[ "$status" -eq 2 ]]
    [[ "${#lines[@]}" -eq 1 && "$output" != *" at "* ]] || { echo "$output"; return 1; }

    fixture 'const TABS' 'throw new Error("boom"); const TABS'
    run node "$CHECK" "$FIXTURE"
    [[ "$output" == *"remove DOM calls that check-widget does not stub"* ]] || { echo "$output"; return 1; }
}

@test "CURE2-1: a var() fallback resolves when the host variable is not defined" {
    fixture "--fg: #ececec" "--fg: var(--host-fg, #ececec)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

    fixture "--fg: #ececec" "--fg: var(--host-fg, #626262)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"dark:--fg/--bg [contrast] "*":1, limit 4.5:1"* && "$output" != *unchecked* ]] || { echo "$output"; return 1; }

    fixture "--fg: #ececec" "--fg: var(--host-fg)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"dark:--fg/--bg [contrast] unchecked"*"hex fallback"* ]] || { echo "$output"; return 1; }
}

@test "CURE2-2: a missing dark block gives one finding, not a repeat of each light failure" {
    fixture "@media (prefers-color-scheme: dark)" "@media (prefers-color-scheme: light)"
    fixture_more "--fg: #222222" "--fg: #dddddd"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"light:--fg/--bg [contrast]"* && "$output" == *"dark [contrast] no dark block"* && "$output" != *"dark:--"* ]] || { echo "$output"; return 1; }
}

@test "CURE2-3: check-widget reports a non-string plain field and checks TABS x" {
    fixture "x:'Example proposal A. No architecture facts are verified.'" "x:{A:'one', B:'two'}"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"TABS.A.x [plain-words] the field is object, not a string"* ]] || { echo "$output"; return 1; }

    fixture "x:'Example proposal A. No architecture facts are verified.'" "x:'$(n_words 26)'"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"TABS.A.x [plain-words] 26 words"* ]] || { echo "$output"; return 1; }

    fixture "a:'Unverified example: proposal A sends" "a:{A:'short.'}, b0:'proposal A sends"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"TABS.A.a [plain-words] the field is object, not a string"* ]] || { echo "$output"; return 1; }
}

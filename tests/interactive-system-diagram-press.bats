#!/usr/bin/env bats
# Adversarial (press) pass for interactive-system-diagram. Tests only; no production edits.

load test_helper

load interactive-system-diagram

# ---------------------------------------------------------------- check-widget

@test "PRESS-1: escaped close-script tag inside a string is read as data and exits 0" {
    fixture "$PLAIN_P" 'Close tag <\/script> is fine. Unverified.'
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ -z "$output" ]]
}

@test "PRESS-2: raw close-script tag inside a string yields a load finding, not a crash" {
    fixture "$PLAIN_P" 'Close tag </script> breaks the page. Unverified.'
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"script [load]"*" → "* ]] || { echo "$output"; return 1; }
}

@test "PRESS-3: missing inline script exits 1 with a load finding" {
    run node "$CHECK" "$FIXTURES/no-script.html"
    [[ "$status" -eq 1 ]]
    [[ "${lines[0]}" == "script [load] no inline script found → add the widget script" ]] || { echo "$output"; return 1; }
}

@test "PRESS-4: a throwing script and an endless loop both exit 1 with a load finding" {
    run node "$CHECK" "$FIXTURES/script-throws.html"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"script [load]"*"boom from fixture"* ]] || { echo "$output"; return 1; }
    run node "$CHECK" "$FIXTURES/script-loops.html"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"script [load]"* ]] || { echo "$output"; return 1; }
}

@test "PRESS-5: no argument exits 2 with a usage line" {
    run node "$CHECK"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"usage"* ]]
}

@test "PRESS-6: answer sentence of exactly 20 words passes and 21 words fails alone" {
    fixture "$ANSWER_A" "$(n_words 20)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    fixture "$ANSWER_A" "$(n_words 21)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == "TABS.A.a [answer-words] 21 words in the answer, limit 20 → "* ]] || { echo "$output"; return 1; }
    [[ "$(echo "$output" | wc -l)" -eq 1 ]]
}

@test "PRESS-7: why field of exactly 25 words passes and 26 words fails under T1.why" {
    fixture "$WHY_1" "$(n_words 25)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    fixture "$WHY_1" "$(n_words 26)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == "T1.why [plain-words]"* ]] || { echo "$output"; return 1; }
}

@test "PRESS-8: empty and whitespace-only p fields do not crash or report" {
    fixture "$PLAIN_P" ""
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    fixture "$PLAIN_P" "   "
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "PRESS-9: sentence terminators ! and ? count: 6 sentences pass, 7 fail" {
    fixture "$PLAIN_P" "A one! B two? C three. D four! E five? F six."
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    fixture "$PLAIN_P" "A one! B two? C three. D four! E five? F six. G seven?"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"caller.p [sentence-count] 7 sentences, limit 6"* ]] || { echo "$output"; return 1; }
}

@test "PRESS-10: a version number such as v1.2 is not a sentence break" {
    fixture "$PLAIN_P" "One. Two. Three. Four. Five. Uses v1.2 of the API."
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "PRESS-11: abbreviations e.g. and U.S. do not inflate the sentence count (speculative)" {
    # Six real sentences; the splitter must not count the abbreviation as a break.
    fixture "$PLAIN_P" "One. Two. Three. Four. Five. Use a proxy, e.g. the gateway."
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "e.g.: $output"; return 1; }
    fixture "$PLAIN_P" "One. Two. Three. Four. Five. The U.S. Army ran it."
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "U.S.: $output"; return 1; }
}

@test "PRESS-12: an answer of two short sentences breaks the one-sentence rule (speculative)" {
    fixture "$ANSWER_A" "Unverified example: proposal A uses the gateway for all requests today. One link is not checked yet and needs review."
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]] || { echo "two-sentence answer accepted"; return 1; }
}

@test "PRESS-13: contrast accepts 3-digit hex and rgb() forms and reports a dark-only failure" {
    fixture "--fg: #222222" "--fg: #222"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "3-digit pass: $output"; return 1; }
    fixture "--fg: #222222" "--fg: rgb(34, 34, 34)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 0 ]] || { echo "rgb pass: $output"; return 1; }
    fixture "--fg: #ececec" "--fg: #666"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"dark:--fg/--bg [contrast]"* && "$output" != *"light:"* ]] || { echo "$output"; return 1; }
    fixture "--muted: #595959" "--muted: rgb(138,138,138)"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"light:--muted/--bg [contrast]"* && "$output" != *"dark:--muted"* ]] || { echo "$output"; return 1; }
}

@test "PRESS-14: every finding line matches the key [rule] message arrow fix shape" {
    fixture "$ANSWER_A" "$(n_words 21)"
    fixture_more "$PLAIN_P" "$(n_words 26)"
    fixture_more "--fg: #ececec" "--fg: #666"
    run node "$CHECK" "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$(echo "$output" | wc -l)" -ge 3 ]] || { echo "$output"; return 1; }
    while IFS= read -r line; do
        [[ "$line" =~ ^[^[:space:]]+\ \[[a-z-]+\]\ .+\ →\ .+$ ]] || { echo "bad line: $line"; return 1; }
    done <<< "$output"
}

@test "PRESS-15: CRLF line endings do not hide the dark block or break script loading" {
    node -e "const fs=require('fs');fs.writeFileSync(process.argv[2],fs.readFileSync(process.argv[1],'utf8').replace(/\n/g,'\r\n'))" "$ASSET" "$BATS_TEST_TMPDIR/crlf.html"
    run node "$CHECK" "$BATS_TEST_TMPDIR/crlf.html"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    node -e "const fs=require('fs');const f=process.argv[1];fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('--fg: #ececec','--fg: #666666'))" "$BATS_TEST_TMPDIR/crlf.html"
    run node "$CHECK" "$BATS_TEST_TMPDIR/crlf.html"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"dark:--fg/--bg [contrast]"* ]] || { echo "$output"; return 1; }
}

@test "PRESS-27: the suites avoid GNU-only in-place sed and timeout, which stock macOS lacks" {
    run grep -nE 'sed [-]i|timeout [2]0' "$BATS_TEST_DIRNAME/interactive-system-diagram.bats" "$BATS_TEST_DIRNAME/interactive-system-diagram-press.bats"
    [[ "$status" -eq 1 ]] || { echo "$output"; return 1; }
}

# ---------------------------------------------------------------- widget state

@test "PRESS-16: Back at step 1 stays on step 1 and Next on the last step ends the walkthrough" {
    vm_run <<'NODE'
const env = load(), m = env.m;
env.level(1);
env.id('walk').handlers.click();
env.id('back').handlers.click();
env.id('back').handlers.click();
assert.equal(env.panel().pb.textContent, m.W[0].cap);
assert.equal(env.panel().ph.textContent, 'Step 1 of ' + m.W.length);
for (let i = 1; i < m.W.length; i++) env.id('next').handlers.click();
assert.equal(env.panel().pb.textContent, m.W[m.W.length - 1].cap);
env.id('next').handlers.click();
assert.equal(env.id('next').disabled, true);
assert.equal(env.id('back').disabled, true);
env.id('next').handlers.click();
env.id('back').handlers.click();
assert.equal(env.ev('walk'), null);
assert.equal(env.ev('lv'), 1);
assert.equal(env.panel().ph.textContent, m.TABS.A.n);
NODE
}

@test "PRESS-17: Esc twice is idempotent and keeps tab and level" {
    vm_run <<'NODE'
const env = load(), m = env.m;
env.tab('B'); env.level(2);
env.id('walk').handlers.click();
env.esc(); env.esc();
assert.equal(env.ev('tab'), 'B');
assert.equal(env.ev('lv'), 2);
assert.equal(env.panel().ph.textContent, m.TABS.B.n);
assert.equal(env.panel().ps.textContent, m.TABS.B.s);
assert.equal(env.id('next').disabled, true);
for (const k in env.keys) assert.notEqual(env.keys[k].style.opacity, '0.25', k);
NODE
}

@test "PRESS-18: clicking Walk again mid-walk must not lose the original tab and level" {
    vm_run <<'NODE'
const env = load(), m = env.m;
env.tab('B'); env.level(1);
env.id('walk').handlers.click();
for (let i = 1; i < m.W.length; i++) env.id('next').handlers.click();
env.id('walk').handlers.click();
env.esc();
assert.equal(env.ev('tab') + '/' + env.ev('lv'), 'B/1');
NODE
}

@test "PRESS-19: picking a tab or level mid-walk ends the walk without restoring the old view" {
    vm_run <<'NODE'
const env = load(), m = env.m;
env.level(0);
env.id('walk').handlers.click();
env.id('next').handlers.click();
env.level(2);
assert.equal(env.ev('lv'), 2);
assert.equal(env.id('next').disabled, true);
for (const k in env.keys) assert.notEqual(env.keys[k].style.opacity, '0.25', k);
env.id('walk').handlers.click();
env.tab('B');
assert.equal(env.ev('tab'), 'B');
assert.equal(env.ev('walk'), null);
assert.equal(env.panel().ph.textContent, m.TABS.B.n);
NODE
}

@test "PRESS-20: a tab with zero open tensions shows count 0 and an empty chip list" {
    vm_run <<'NODE'
const env = load(), m = env.m;
env.ev("T.T1.tabs = ['B']");
env.level(2);
env.tab('A');
assert.equal(env.id('tc').textContent, '0 open tensions');
for (const k in env.m.T) assert.ok(consistent(env.keys[k]) && env.keys[k].attrs['aria-hidden'] === 'true', k);
env.focus('tensions');
assert.equal(env.panel().pm.textContent, '');
for (const k in m.T) assert.ok(!env.panel().pm.textContent.includes(m.T[k].t), k);
assert.ok(consistent(env.keys.tensions) && env.keys.tensions.attrs['aria-hidden'] === 'false');
env.tab('B');
assert.equal(env.id('tc').textContent, '2 open tensions');
env.ev("T.T2.tabs = ['B']; T.T1.tabs = []");
env.tab('B');
assert.equal(env.id('tc').textContent, '1 open tension');
NODE
}

@test "PRESS-21: every tension badge is hidden at L0 on every tab, and a tab switch at L0 keeps L0" {
    vm_run <<'NODE'
const env = load(), m = env.m;
for (const tab of Object.keys(m.TABS)) {
  env.level(0);
  env.tab(tab);
  assert.equal(env.ev('lv'), 0, tab);
  for (const k in m.T) {
    assert.equal(env.keys[k].attrs['aria-hidden'], 'true', tab + ' ' + k);
    assert.equal(env.keys[k].attrs.tabindex, '-1', tab + ' ' + k);
    assert.equal(env.keys[k].style.opacity, '0', tab + ' ' + k);
  }
  assert.equal(env.id('fence').style.opacity, '0');
  assert.equal(env.lvEls[0].attrs['aria-pressed'], 'true');
}
NODE
}

@test "PRESS-22: group edge takes the worst member state for every pair (u > p > m > v)" {
    vm_run <<'NODE'
const env = load(), m = env.m;
const order = 'vmpu';
const line = env.id('v_e_g_entry_core');
for (const a of order) for (const b of order) {
  env.ev(`E.e_gateway_orders.s.A = '${a}'; E.e_auth_billing.s.A = '${b}'`);
  env.tab('B'); env.tab('A');
  const worst = order[Math.max(order.indexOf(a), order.indexOf(b))];
  assert.equal(line.style.stroke, 'var(--edge-' + worst + ')', a + b);
  assert.equal(line.attrs['stroke-dasharray'], m.S[worst].d, a + b);
  env.focus('e_g_entry_core');
  assert.equal(env.panel().ph.children[0].textContent, m.S[worst].l, a + b);
}
NODE
}

@test "PRESS-23: node source falls back to the tab note and resolves per-tab maps, including a missing tab entry" {
    vm_run <<'NODE'
const env = load(), m = env.m;
env.level(2);
for (const tab of ['A', 'B']) {
  env.tab(tab);
  env.focus('caller');
  assert.equal(env.panel().ps.textContent, m.TABS[tab].s, 'no src ' + tab);
  env.focus('orders');
  assert.equal(env.panel().ps.textContent, m.N.orders.src, 'string src ' + tab);
  env.focus('billing');
  assert.equal(env.panel().ps.textContent, m.N.billing.src[tab], 'map src ' + tab);
}
env.ev("N.billing.src = {A: 'only A'}");
env.tab('B'); env.focus('billing');
assert.equal(env.panel().ps.textContent, m.TABS.B.s);
env.ev("N.billing.src = ''");
env.focus('billing');
assert.equal(env.panel().ps.textContent, m.TABS.B.s);
NODE
}

@test "PRESS-24: hostile labels render as text at every level and tab, and the script has no HTML sinks" {
    vm_run <<'NODE'
const env = load(), m = env.m;
assert.doesNotMatch(script, /innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\b|new Function/);
const H = '<img src=x onerror=alert(1)>';
env.ev(`(function (H) {
  for (const k in N) Object.assign(N[k], {t: H, p: H, x: H, sp: H, sx: H, src: H});
  for (const k in G) Object.assign(G[k], {t: H, p: H});
  for (const k in E) Object.assign(E[k], {t: H, p: H}, E[k].of ? {} : {x: H, src: H});
  for (const k in T) Object.assign(T[k], {t: H, p: H, x: H, why: H, src: H});
  for (const k in TABS) Object.assign(TABS[k], {n: H, a: H, x: H, s: H});
  for (const s of W) s.cap = H;
})(${JSON.stringify(H)})`);
const labels = Object.values(m.S).map(s => s.l);
for (const level of [0, 1, 2]) for (const tab of ['A', 'B']) {
  env.level(level); env.tab(tab);
  assert.equal(env.id('ans').textContent, H);
  assert.equal(env.id('ans').children.length, 0);
  for (const k in m.N) assert.equal(env.id('s_' + k).children.length, 0);
  for (const k in env.keys) {
    env.focus(k);
    for (const el of Object.values(env.panel())) {
      for (const c of el.children) {
        assert.ok(labels.includes(c.textContent) && c.children.length === 0, level + tab + k);
      }
    }
  }
  env.id('walk').handlers.click();
  assert.equal(env.panel().pb.textContent, H);
  assert.equal(env.panel().pb.children.length, 0);
  env.esc();
}
env.level(2); env.focus('gateway');
assert.equal(env.panel().ph.textContent, H);
assert.equal(env.panel().pb.textContent, H);
assert.equal(env.panel().px.textContent, H);
assert.equal(env.panel().ps.textContent, H);
NODE
}

@test "PRESS-25: hidden elements stay out of the tab order in every level, tab, and walkthrough step" {
    vm_run <<'NODE'
const env = load(), m = env.m;
function check(label) {
  const lv = env.ev('lv'), tab = env.ev('tab');
  for (const k in env.keys) {
    const e = env.keys[k];
    assert.ok(consistent(e), label + ' inconsistent ' + k);
    assert.equal(e.attrs['aria-hidden'] === 'false', expectShown(m, k, lv, tab), label + ' ' + k + ' L' + lv + tab);
  }
  for (const k in m.E) {
    const e = env.id('v_' + k);
    assert.ok(consistent(e), label + ' line ' + k);
    assert.equal(e.attrs['aria-hidden'] === 'false', expectShown(m, k, lv, tab), label + ' line ' + k);
  }
  const fence = env.id('fence');
  assert.ok(consistent(fence), label + ' fence');
  assert.equal(fence.attrs['aria-hidden'] === 'false', lv > 0 && !!m.TABS[tab].fence, label + ' fence');
}
for (const tab of Object.keys(m.TABS)) for (const level of [0, 1, 2]) {
  env.tab(tab); env.level(level);
  check('plain ' + tab + level);
  env.id('walk').handlers.click();
  check('walk0 ' + tab + level);
  for (let i = 1; i < m.W.length; i++) { env.id('next').handlers.click(); check('step' + i + ' ' + tab + level); }
  env.id('next').handlers.click();
  check('ended ' + tab + level);
  env.id('walk').handlers.click();
  env.esc();
  check('esc ' + tab + level);
}
NODE
}

@test "PRESS-26: no code path sets style.display on any element" {
    vm_run <<'NODE'
const env = load(), m = env.m;
assert.doesNotMatch(script, /display/);
const all = () => [...env.keyEls, ...Object.keys(m.E).map(k => env.id('v_' + k)),
  ...Object.keys(m.N).map(k => env.id('s_' + k)), env.id('fence'), env.id('ans'), env.id('tc'),
  env.id('walk'), env.id('next'), env.id('back'), ...Object.values(env.panel())];
for (const tab of ['A', 'B']) for (const level of [0, 1, 2]) {
  env.tab(tab); env.level(level);
  for (const k in env.keys) env.focus(k);
  env.id('walk').handlers.click();
  for (let i = 0; i < m.W.length; i++) env.id('next').handlers.click();
  env.esc();
  for (const e of all()) assert.equal(e.style.display, undefined, e.id || e.dataset.k);
}
NODE
}

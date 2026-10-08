# Shared prelude for the interactive-system-diagram Bats suites.
# Load it after test_helper: load test_helper; load interactive-system-diagram
# shellcheck disable=SC2034,SC2154  # the loading suites use these values; Bats sets status and output

SKILL_DIR="$REAL_DOTFILES_DIR/skills/interactive-system-diagram"
ASSET="$SKILL_DIR/assets/widget-scaffold.html"
CHECK="$SKILL_DIR/scripts/check-widget.mjs"
SKILL_MD="$SKILL_DIR/SKILL.md"
REFERENCE_MD="$SKILL_DIR/references/widget-scaffold.md"
FIXTURES="$REAL_DOTFILES_DIR/tests/fixtures/interactive-system-diagram"

# Node prelude: a small fake DOM built from the asset's own markup, so ids,
# data-k keys, level buttons, and tab buttons match the real file.
read -r -d '' HARNESS <<'NODE' || true
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const html = fs.readFileSync(process.argv[1], 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const markup = html.slice(0, html.indexOf('<script>'));
function element(id = '') {
  return {id, dataset: {}, attrs: {}, handlers: {}, style: {}, children: [], _t: '', disabled: undefined,
    get textContent() { return this._t; },
    set textContent(v) { this._t = String(v); this.children = []; },
    setAttribute(k, v) { this.attrs[k] = String(v); },
    addEventListener(k, f) { this.handlers[k] = f; },
    append(c) { this.children.push(c); }};
}
function load(missing = []) {
  const byId = new Map(), keyEls = [], lvEls = [], tabEls = [], docHandlers = {};
  for (const tag of markup.match(/<[a-z][^>]*>/g)) {
    const attr = name => (tag.match(new RegExp('\\b' + name + '="([^"]*)"')) || [])[1];
    const id = attr('id'), k = attr('data-k'), lvl = attr('data-lv'), tb = attr('data-tab');
    if (id === undefined && k === undefined && lvl === undefined && tb === undefined) continue;
    const e = element(id || '');
    if (id !== undefined && !missing.includes(id)) byId.set(id, e);
    if (k !== undefined) { e.dataset.k = k; keyEls.push(e); }
    if (lvl !== undefined) { e.dataset.lv = lvl; lvEls.push(e); }
    if (tb !== undefined) { e.dataset.tab = tb; tabEls.push(e); }
  }
  const document = {
    getElementById: id => byId.get(id) || null,
    createElement: () => element(),
    addEventListener(k, f) { docHandlers[k] = f; },
    querySelectorAll: sel => sel === '[data-k]' ? keyEls : sel === '[data-lv]' ? lvEls :
      sel === '.tabs button' ? tabEls : []
  };
  const ctx = vm.createContext({document});
  vm.runInContext(script, ctx, {timeout: 1000});
  const env = {
    ctx, id: i => byId.get(i), keyEls, lvEls, tabEls,
    keys: Object.fromEntries(keyEls.map(e => [e.dataset.k, e])),
    ev: code => vm.runInContext(code, ctx),
    level(n) { lvEls[n].handlers.click(); },
    tab(name) { tabEls.find(b => b.dataset.tab === name).handlers.click(); },
    focus(k) { env.keys[k].handlers.focus(); },
    esc() { docHandlers.keydown({key: 'Escape'}); },
    panel: () => ({ph: byId.get('ph'), pb: byId.get('pb'), px: byId.get('px'), pm: byId.get('pm'), ps: byId.get('ps')})
  };
  env.m = env.ev('({TABS, G, N, E, T, W, S})');
  return env;
}
const shown = e => e.style.opacity !== '0' && e.style.pointerEvents === 'auto' &&
  e.attrs['aria-hidden'] === 'false' && (e.dataset.k === undefined || e.attrs.tabindex === '0');
const hidden = e => e.style.opacity === '0' && e.style.pointerEvents === 'none' &&
  e.attrs['aria-hidden'] === 'true' && (e.dataset.k === undefined || e.attrs.tabindex === '-1');
// A node is internally consistent when opacity, pointer-events, aria-hidden, and tabindex agree.
function consistent(e) {
  const h = e.attrs['aria-hidden'];
  if (h !== 'true' && h !== 'false') return false;
  const off = h === 'true';
  const base = off ? (e.style.opacity === '0' && e.style.pointerEvents === 'none')
    : (e.style.opacity !== '0' && e.style.pointerEvents === 'auto');
  if (e.dataset.k === undefined) return base;
  return base && e.attrs.tabindex === (off ? '-1' : '0');
}
function boxShown(m, k, level) { return !!m.G[k] || (!!m.N[k] && (!m.N[k].g || level > 0)); }
function expectShown(m, k, level, tab) {
  if (m.G[k] || m.N[k]) return boxShown(m, k, level);
  if (m.E[k]) return m.E[k].of ? level === 0 : boxShown(m, m.E[k].a, level) && boxShown(m, m.E[k].b, level);
  if (m.T[k]) return level > 0 && m.T[k].tabs.includes(tab);
  return k === 'tensions';
}
const words = s => s.split(/\s+/).filter(Boolean).length;
const openTensions = (m, tab) => Object.keys(m.T).filter(k => m.T[k].tabs.includes(tab));
NODE

vm_run() {
    run node -e "$HARNESS"$'\n'"$(cat)" "$ASSET"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

# fixture <old> <new>: copy the asset to $FIXTURE with the first <old> replaced.
fixture() {
    FIXTURE="$BATS_TEST_TMPDIR/widget.html"
    node -e "const fs = require('fs'); const [src, dst, from, to] = process.argv.slice(1);
const t = fs.readFileSync(src, 'utf8'); if (!t.includes(from)) throw new Error('fixture text missing: ' + from);
fs.writeFileSync(dst, t.replace(from, () => to));" "$ASSET" "$FIXTURE" "$1" "$2"
}

# fixture_more <old> <new>: apply one more replacement to the existing $FIXTURE.
fixture_more() {
    node -e "const fs = require('fs'); const [dst, from, to] = process.argv.slice(1);
const t = fs.readFileSync(dst, 'utf8'); if (!t.includes(from)) throw new Error('fixture text missing: ' + from);
fs.writeFileSync(dst, t.replace(from, () => to));" "$FIXTURE" "$1" "$2"
}

n_words() {
    local text
    text=$(printf 'word %.0s' $(seq "$1"))
    echo "${text% }."
}

ANSWER_A='Unverified example: proposal A sends every request through the gateway, and one link is not checked.'
PLAIN_P='Example client that sends requests. Unverified.'
WHY_1='The decision stays open until someone checks both sources.'

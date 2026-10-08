#!/usr/bin/env bats

load test_helper

ASSET="$REAL_DOTFILES_DIR/skills/interactive-system-diagram/assets/widget-scaffold.html"

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
for (const id of ['ph', 'pb', 'ps', 'fence', 'v_e_caller_entry', 'v_e_entry_core']) {
  assert.match(html, new RegExp('id="' + id + '"'));
}
for (const key of ['caller', 'entry', 'core', 'e_caller_entry', 'e_entry_core', 'T1']) {
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
    run node - "$ASSET" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const html = fs.readFileSync(process.argv[2], 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const nodes = new Map();
function element(id = '') {
  return {id, dataset: {}, attrs: {}, handlers: {},
    style: {}, children: [], textContent: '',
    setAttribute(k,v) { this.attrs[k] = v; },
    addEventListener(k,v) { this.handlers[k] = v; },
    append(child) { this.children.push(child); }};
}
for (const id of ['ph','pb','ps','v_e_caller_entry','v_e_entry_core','fence']) nodes.set(id, element(id));
const a = element(), b = element();
a.dataset.tab = 'A'; b.dataset.tab = 'B';
const keys = ['entry','core','e_entry_core','T1'].map(k => {
  const el = element(); el.dataset.k = k; return el;
});
const document = {
  getElementById: id => nodes.get(id) || null,
  createElement: () => element(),
  querySelectorAll: selector => selector === '.tabs button' ? [a,b] :
    selector === '[data-k]' ? keys : []
};
const context = vm.createContext({document});
vm.runInContext(script, context, {timeout: 1000});
assert.equal(a.attrs['aria-selected'], 'true');
assert.equal(nodes.get('v_e_entry_core').attrs.stroke, '#E24B4A');
assert.equal(nodes.get('fence').attrs.opacity, '0');
assert.equal(keys[0].attrs.tabindex, '0');
keys[2].handlers.focus();
assert.equal(nodes.get('ps').textContent, 'Example edge source A. Unverified.');
assert.equal(nodes.get('ph').children.length, 1);
keys[3].handlers.mouseenter();
assert.match(nodes.get('ps').textContent, /Why it matters:/);
keys[0].handlers.focus();
assert.equal(nodes.get('ps').textContent, 'Example note A. Unverified.');
b.handlers.click();
assert.equal(b.attrs['aria-selected'], 'true');
assert.equal(nodes.get('v_e_entry_core').attrs.stroke, '#888780');
assert.equal(nodes.get('v_e_entry_core').attrs['stroke-dasharray'], '6 3 1 3');
assert.equal(nodes.get('fence').attrs.opacity, '1');
assert.equal(nodes.get('ps').textContent, 'Example note B. Unverified.');
keys[2].handlers.focus();
assert.equal(nodes.get('ps').textContent, 'Example edge source B. Unverified.');
vm.runInContext("N.entry[0] = '<img src=x onerror=alert(1)>'", context);
keys[0].handlers.focus();
assert.equal(nodes.get('ph').textContent, '<img src=x onerror=alert(1)>');
assert.equal(nodes.get('ps').textContent, 'Example note B. Unverified.');
nodes.delete('fence');
vm.runInNewContext(script, {document}, {timeout: 1000});
assert.equal(a.attrs['aria-selected'], 'true');
NODE
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

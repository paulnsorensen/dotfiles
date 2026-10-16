import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { WFX, runWfx, tempDir } from './fx-kit.mjs';

function setup(t) {
  const state = tempDir(t, 'wfx-state-');
  return { state, cwd: tempDir(t), env: { ...process.env, WFX_STATE_DIR: state } };
}

function putStdin(args, input, { cwd, env }) {
  const res = spawnSync(WFX, ['run-state', 'put', ...args], { cwd, env, input, encoding: 'utf8' });
  return { status: res.status, json: JSON.parse(res.stdout) };
}

const PLAN = { prs: [1, 2], nested: { a: [true, null, 'xé'], n: 1.5 }, empty: {} };

test('put from stdin then get in a later process returns identical JSON', (t) => {
  const ctx = setup(t);
  const put = putStdin(['--landing', 'land1', '--key', 'plan'], JSON.stringify(PLAN), ctx);
  assert.equal(put.status, 0, JSON.stringify(put.json));
  assert.equal(put.json.data.path, join(ctx.state, 'land1', 'plan.json'));
  const got = runWfx(['run-state', 'get', '--landing', 'land1', '--key', 'plan'], ctx);
  assert.equal(got.status, 0);
  assert.deepEqual(got.json.data.value, PLAN);
});

test('put --file stores the file content', (t) => {
  const ctx = setup(t);
  const file = join(ctx.cwd, 'plan.json');
  writeFileSync(file, JSON.stringify(PLAN, null, 2));
  assert.equal(runWfx(['run-state', 'put', '--landing', 'l', '--key', 'k', '--file', file], ctx).status, 0);
  assert.deepEqual(runWfx(['run-state', 'get', '--landing', 'l', '--key', 'k'], ctx).json.data.value, PLAN);
});

test('put overwrites and leaves no temp files', (t) => {
  const ctx = setup(t);
  putStdin(['--landing', 'l', '--key', 'k'], '{"v":1}', ctx);
  putStdin(['--landing', 'l', '--key', 'k'], '{"v":2}', ctx);
  assert.deepEqual(runWfx(['run-state', 'get', '--landing', 'l', '--key', 'k'], ctx).json.data.value, { v: 2 });
  assert.deepEqual(readdirSync(join(ctx.state, 'l')), ['k.json']);
});

test('put rejects invalid JSON and stores nothing', (t) => {
  const ctx = setup(t);
  const put = putStdin(['--landing', 'l', '--key', 'k'], '{not json', ctx);
  assert.equal(put.status, 2);
  assert.equal(existsSync(join(ctx.state, 'l', 'k.json')), false);
});

test('get of a missing key exits 1 with not-found', (t) => {
  const ctx = setup(t);
  const got = runWfx(['run-state', 'get', '--landing', 'l', '--key', 'nope'], ctx);
  assert.equal(got.status, 1);
  assert.equal(got.json.error.code, 'not-found');
});

test('list returns sorted keys and empty for an unknown landing', (t) => {
  const ctx = setup(t);
  putStdin(['--landing', 'l', '--key', 'b'], '1', ctx);
  putStdin(['--landing', 'l', '--key', 'a'], '2', ctx);
  assert.deepEqual(runWfx(['run-state', 'list', '--landing', 'l'], ctx).json.data.keys, ['a', 'b']);
  assert.deepEqual(runWfx(['run-state', 'list', '--landing', 'other'], ctx).json.data.keys, []);
});

test('ids and keys that do not match the pattern are bad input', (t) => {
  const ctx = setup(t);
  for (const bad of ['../x', 'A', '-a', 'a/b', '', 'x'.repeat(65)]) {
    assert.equal(runWfx(['run-state', 'get', '--landing', bad, '--key', 'k'], ctx).status, 2, `landing ${bad}`);
    assert.equal(runWfx(['run-state', 'get', '--landing', 'l', '--key', bad], ctx).status, 2, `key ${bad}`);
  }
  assert.equal(runWfx(['run-state', 'get', '--landing', 'x'.repeat(64), '--key', 'k'], ctx).status, 1);
});

test('state lands under XDG_STATE_HOME/wfx when WFX_STATE_DIR is unset', (t) => {
  const xdg = tempDir(t, 'wfx-xdg-');
  const env = { ...process.env, XDG_STATE_HOME: xdg };
  delete env.WFX_STATE_DIR;
  assert.equal(putStdin(['--landing', 'l', '--key', 'k'], '[1]', { cwd: xdg, env }).status, 0);
  assert.equal(readFileSync(join(xdg, 'wfx', 'l', 'k.json'), 'utf8'), '[1]');
});

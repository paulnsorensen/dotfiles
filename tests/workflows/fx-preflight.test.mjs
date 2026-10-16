import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fakeGh, pathWith, runWfx, tempDir, wfxBinDir } from './fx-kit.mjs';

const AUTH_OK = { 'auth status': { stdout: 'logged in\n', status: 0 } };
const AUTH_BAD = { 'auth status': { stderr: 'not logged in', status: 1 } };

function fakePython(t, exitCode) {
  const dir = tempDir(t, 'wfx-py-');
  const path = join(dir, 'python-fake');
  writeFileSync(path, `#!/bin/sh\nexit ${exitCode}\n`);
  chmodSync(path, 0o755);
  return path;
}

function setup(t, { gh = AUTH_OK, pythonExit = 0, withWfx = true } = {}) {
  const ghKit = fakeGh(gh, t);
  const extra = [ghKit.binDir];
  if (withWfx) extra.push(wfxBinDir(t));
  return { python: fakePython(t, pythonExit), env: { ...process.env, PATH: pathWith(...extra) }, cwd: tempDir(t) };
}

function failedNames(json) {
  return json.error.details.checks.filter((c) => !c.ok).map((c) => c.name);
}

test('success with fakes reports every check ok', (t) => {
  const { python, env, cwd } = setup(t);
  const wt = tempDir(t);
  const { status, json } = runWfx(['preflight', '--python', python, '--worktree', wt], { cwd, env });
  assert.equal(status, 0);
  assert.equal(json.ok, true);
  const names = json.data.checks.map((c) => c.name);
  assert.deepEqual(names, ['git', 'node', 'wfx', 'gh', 'pytest', `worktree:${wt}`]);
  assert.ok(json.data.checks.every((c) => c.ok));
  assert.match(json.data.checks[0].detail, /git version/);
});

test('pytest import failure fails preflight (AC-11)', (t) => {
  const { python, env, cwd } = setup(t, { pythonExit: 1 });
  const { status, json } = runWfx(['preflight', '--python', python], { cwd, env });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'preflight-failed');
  assert.deepEqual(failedNames(json), ['pytest']);
  assert.match(json.error.message, /pytest/);
  assert.equal(json.error.details.checks.length, 5);
});

test('gh auth failure fails preflight (AC-11)', (t) => {
  const { python, env, cwd } = setup(t, { gh: AUTH_BAD });
  const { status, json } = runWfx(['preflight', '--python', python], { cwd, env });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'preflight-failed');
  assert.deepEqual(failedNames(json), ['gh']);
});

test('wfx missing from PATH fails preflight (AC-11)', (t) => {
  const { python, env, cwd } = setup(t, { withWfx: false });
  const { status, json } = runWfx(['preflight', '--python', python], { cwd, env });
  assert.equal(status, 1);
  assert.deepEqual(failedNames(json), ['wfx']);
});

test('missing worktree path fails preflight', (t) => {
  const { python, env, cwd } = setup(t);
  const missing = join(tempDir(t), 'nope');
  const { status, json } = runWfx(['preflight', '--python', python, '--worktree', missing], { cwd, env });
  assert.equal(status, 1);
  assert.deepEqual(failedNames(json), [`worktree:${missing}`]);
});

test('read-only worktree fails preflight (AC-11)', { skip: process.getuid?.() === 0 && 'root ignores chmod' }, (t) => {
  const { python, env, cwd } = setup(t);
  const ro = join(tempDir(t), 'ro');
  mkdirSync(ro);
  chmodSync(ro, 0o555);
  const { status, json } = runWfx(['preflight', '--python', python, '--worktree', ro], { cwd, env });
  assert.equal(status, 1);
  assert.deepEqual(failedNames(json), [`worktree:${ro}`]);
});

test('several failures are all named in the message', (t) => {
  const { python, env, cwd } = setup(t, { gh: AUTH_BAD, pythonExit: 1, withWfx: false });
  const { json } = runWfx(['preflight', '--python', python], { cwd, env });
  assert.deepEqual(failedNames(json).sort(), ['gh', 'pytest', 'wfx']);
  for (const name of ['gh', 'pytest', 'wfx']) assert.match(json.error.message, new RegExp(name));
});

test('--need limits the checks that run', (t) => {
  const { env, cwd } = setup(t, { gh: AUTH_BAD, withWfx: false });
  const { status, json } = runWfx(['preflight', '--need', 'git,node'], { cwd, env });
  assert.equal(status, 0);
  assert.deepEqual(json.data.checks.map((c) => c.name), ['git', 'node']);
});

test('unknown --need entry is bad input', (t) => {
  const { env, cwd } = setup(t);
  const { status, json } = runWfx(['preflight', '--need', 'git,bogus'], { cwd, env });
  assert.equal(status, 2);
  assert.equal(json.error.code, 'bad-input');
});

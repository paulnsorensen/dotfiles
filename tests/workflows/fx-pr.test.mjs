import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fakeGh, pathWith, runWfx, tempDir } from './fx-kit.mjs';

function setup(fixtures, t) {
  const { binDir, logPath } = fakeGh(fixtures, t);
  const env = { ...process.env, PATH: pathWith(binDir) };
  const calls = () => (existsSync(logPath) ? readFileSync(logPath, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
  const cwd = tempDir(t);
  const body = join(cwd, 'body.md');
  writeFileSync(body, 'the body\n');
  return { env, cwd, calls, body };
}

test('pr create passes the branches, title, and body file to gh and parses the URL', (t) => {
  const { env, cwd, calls, body } = setup({}, t);
  const url = 'https://github.com/o/r/pull/42';
  const fx = fakeGh({ [`pr create --repo o/r --base main --head land/x --title feat: x --body-file ${body}`]: { stdout: `Creating...\n${url}\n` } }, t);
  const res = runWfx(['pr', 'create', '--repo-slug', 'o/r', '--base', 'main', '--head', 'land/x', '--title', 'feat: x', '--body-file', body], { cwd, env: { ...env, PATH: pathWith(fx.binDir) } });
  assert.equal(res.status, 0, JSON.stringify(res.json));
  assert.deepEqual(res.json.data, { number: 42, url });
  assert.deepEqual(JSON.parse(readFileSync(fx.logPath, 'utf8').trim()), ['pr', 'create', '--repo', 'o/r', '--base', 'main', '--head', 'land/x', '--title', 'feat: x', '--body-file', body]);
  assert.deepEqual(calls(), []);
});

test('pr create rejects a bad slug, branch, title, missing body file, and missing flag', (t) => {
  const { env, cwd, calls, body } = setup({}, t);
  const ok = ['--base', 'main', '--head', 'x', '--title', 't', '--body-file', body];
  const run = (...args) => runWfx(['pr', 'create', ...args], { cwd, env }).status;
  assert.equal(run('--repo-slug', 'nope', ...ok), 2);
  assert.equal(run('--base', '--evil', '--head', 'x', '--title', 't', '--body-file', body), 2);
  assert.equal(run('--base', 'main', '--head', 'x', '--title', 'a\nb', '--body-file', body), 2);
  assert.equal(run('--base', 'main', '--head', 'x', '--title', 't', '--body-file', join(cwd, 'missing.md')), 2);
  assert.equal(run('--base', 'main', '--head', 'x', '--title', 't'), 2);
  assert.deepEqual(calls(), []);
});

test('pr create fails with pr-create-failed when gh fails', (t) => {
  const { env, cwd, body } = setup({}, t);
  const res = runWfx(['pr', 'create', '--base', 'main', '--head', 'x', '--title', 't', '--body-file', body], { cwd, env });
  assert.equal(res.status, 1);
  assert.equal(res.json.error.code, 'pr-create-failed');
});

test('pr retarget edits the PR base', (t) => {
  const { env, cwd, calls } = setup({}, t);
  const fx = fakeGh({ 'pr edit 7 --base main': {} }, t);
  const res = runWfx(['pr', 'retarget', '--pr', '7', '--base', 'main'], { cwd, env: { ...env, PATH: pathWith(fx.binDir) } });
  assert.equal(res.status, 0, JSON.stringify(res.json));
  assert.deepEqual(res.json.data, { pr: 7, base: 'main' });
  assert.deepEqual(JSON.parse(readFileSync(fx.logPath, 'utf8').trim()), ['pr', 'edit', '7', '--base', 'main']);
  assert.deepEqual(calls(), []);
  assert.equal(runWfx(['pr', 'retarget', '--pr', '7;x', '--base', 'main'], { cwd, env }).status, 2);
  assert.equal(runWfx(['pr', 'retarget', '--pr', '7', '--base', 'a..b'], { cwd, env }).status, 2);
});

test('pr comment posts the body from a file, never from argv text', (t) => {
  const { env, cwd, body } = setup({}, t);
  const fx = fakeGh({ [`pr comment 7 --body-file ${body}`]: {} }, t);
  const res = runWfx(['pr', 'comment', '--pr', '7', '--body-file', body], { cwd, env: { ...env, PATH: pathWith(fx.binDir) } });
  assert.equal(res.status, 0, JSON.stringify(res.json));
  assert.deepEqual(res.json.data, { pr: 7, commented: true });
  assert.deepEqual(JSON.parse(readFileSync(fx.logPath, 'utf8').trim()), ['pr', 'comment', '7', '--body-file', body]);
  assert.equal(runWfx(['pr', 'comment', '--pr', '7', '--body-file', join(cwd, 'gone.md')], { cwd, env }).status, 2);
});

test('pr rejects an unknown subcommand', (t) => {
  const { env, cwd } = setup({}, t);
  assert.equal(runWfx(['pr', 'bogus'], { cwd, env }).status, 2);
});

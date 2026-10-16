import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { runWfx, tempDir, tempRepo } from './fx-kit.mjs';

const SCRATCH_SRC = (() => {
  const text = readFileSync(new URL('../../claude/workflow-prelude/prelude.js', import.meta.url), 'utf8');
  const m = text.match(/const SCRATCH_PATH_SRC = String\.raw`([^`]+)`/);
  assert.ok(m, 'prelude defines SCRATCH_PATH_SRC');
  return new RegExp(`^${m[1]}$`);
})();

function git(cwd, args) {
  const res = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(res.status, 0, `git ${args.join(' ')}: ${res.stderr}`);
  return res.stdout.trim();
}

const add = (repo, landing, name, cwd) =>
  runWfx(['worktree', 'add', '--repo', repo, '--landing', landing, '--name', name, '--ref', 'main'], { cwd });

test('worktree add creates a detached worktree under the scratch root', (t) => {
  const repo = tempRepo(t);
  // Real checkouts ignore .claude/worktrees; mirror that here.
  appendFileSync(join(repo, '.git', 'info', 'exclude'), '.claude/\n');
  const before = git(repo, ['status', '--porcelain']);
  const { status, json } = add(repo, 'land1', 'build-a', tempDir(t));
  assert.equal(status, 0, JSON.stringify(json));
  assert.equal(json.data.path, join(repo, '.claude', 'worktrees', 'land1@build-a'));
  assert.ok(SCRATCH_SRC.test(json.data.path), 'path matches the prelude scratch pattern');
  assert.ok(existsSync(join(json.data.path, 'README.md')));
  assert.equal(json.data.head, git(repo, ['rev-parse', 'main']));
  assert.equal(git(repo, ['status', '--porcelain']), before);
});

test('worktree list shows leftovers and filters by landing', (t) => {
  const repo = tempRepo(t);
  const cwd = tempDir(t);
  add(repo, 'land1', 'a', cwd);
  add(repo, 'land1', 'b', cwd);
  add(repo, 'land2', 'a', cwd);
  git(repo, ['worktree', 'add', '--detach', join(tempDir(t), 'foreign'), 'main']);

  const all = runWfx(['worktree', 'list', '--repo', repo], { cwd });
  assert.equal(all.status, 0);
  assert.deepEqual(all.json.data.worktrees.map((w) => [w.landing, w.name]).sort(), [['land1', 'a'], ['land1', 'b'], ['land2', 'a']]);

  const one = runWfx(['worktree', 'list', '--repo', repo, '--landing', 'land1'], { cwd });
  assert.deepEqual(one.json.data.worktrees.map((w) => w.name).sort(), ['a', 'b']);
  assert.equal(one.json.data.root, join(repo, '.claude', 'worktrees'));
});

test('worktree list from inside a worktree reports the main checkout root', (t) => {
  const repo = tempRepo(t);
  const cwd = tempDir(t);
  const made = add(repo, 'land1', 'a', cwd).json.data.path;
  const { json } = runWfx(['worktree', 'list'], { cwd: made });
  assert.deepEqual(json.data.worktrees.map((w) => w.name), ['a']);
});

test('worktree remove deletes the worktree and its listing', (t) => {
  const repo = tempRepo(t);
  const cwd = tempDir(t);
  const path = add(repo, 'land1', 'a', cwd).json.data.path;
  const { status, json } = runWfx(['worktree', 'remove', '--repo', repo, '--path', path], { cwd });
  assert.equal(status, 0, JSON.stringify(json));
  assert.equal(existsSync(path), false);
  assert.deepEqual(runWfx(['worktree', 'list', '--repo', repo], { cwd }).json.data.worktrees, []);
});

test('worktree remove refuses paths outside the scratch root', (t) => {
  const repo = tempRepo(t);
  const cwd = tempDir(t);
  assert.equal(runWfx(['worktree', 'remove', '--repo', repo, '--path', repo], { cwd }).status, 2);
  assert.ok(existsSync(join(repo, 'README.md')));
});

test('worktree rejects bad ids, unknown subcommands, and bad refs', (t) => {
  const repo = tempRepo(t);
  const cwd = tempDir(t);
  assert.equal(add(repo, '../x', 'a', cwd).status, 2);
  assert.equal(add(repo, 'land1', 'A B', cwd).status, 2);
  assert.equal(runWfx(['worktree', 'bogus'], { cwd }).status, 2);
  const bad = runWfx(['worktree', 'add', '--repo', repo, '--landing', 'l', '--name', 'n', '--ref', 'nope'], { cwd });
  assert.equal(bad.status, 1);
  assert.equal(bad.json.error.code, 'worktree-failed');
});

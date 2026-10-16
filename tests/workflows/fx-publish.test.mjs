import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { bareRemote, commitFiles, runWfx, tempDir, tempRepo } from './fx-kit.mjs';

function git(cwd, args) {
  const res = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(res.status, 0, `git ${args.join(' ')}: ${res.stderr}`);
  return res.stdout.trim();
}

function setup(t) {
  const repo = tempRepo(t);
  const remote = bareRemote(repo, t);
  const sha = commitFiles(repo, { 'a.txt': 'a\n' }, 'work');
  return { repo, remote, sha, cwd: tempDir(t) };
}

test('publish with expect none creates a new remote branch', (t) => {
  const { repo, remote, sha, cwd } = setup(t);
  const head = git(repo, ['rev-parse', 'HEAD']);
  const { status, json } = runWfx(['publish', '--repo', repo, '--branch', 'topic', '--sha', sha, '--expect', 'none'], { cwd });
  assert.equal(status, 0, JSON.stringify(json));
  assert.deepEqual(json.data, { branch: 'topic', sha, expect: 'none', pushed: true });
  assert.equal(git(remote, ['rev-parse', 'refs/heads/topic']), sha);
  assert.equal(git(repo, ['rev-parse', 'HEAD']), head);
  assert.equal(git(repo, ['status', '--porcelain']), '');
});

test('publish with expect none refuses when the remote branch exists', (t) => {
  const { repo, remote, sha, cwd } = setup(t);
  const first = git(repo, ['rev-parse', 'main~1']);
  git(repo, ['push', '-q', 'origin', `${first}:refs/heads/topic`]);
  const { status, json } = runWfx(['publish', '--repo', repo, '--branch', 'topic', '--sha', sha, '--expect', 'none'], { cwd });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'lease-rejected');
  assert.equal(git(remote, ['rev-parse', 'refs/heads/topic']), first);
});

test('publish with a matching expect SHA updates the branch', (t) => {
  const { repo, remote, sha, cwd } = setup(t);
  const first = git(repo, ['rev-parse', 'main~1']);
  git(repo, ['push', '-q', 'origin', `${first}:refs/heads/topic`]);
  const { status } = runWfx(['publish', '--repo', repo, '--branch', 'topic', '--sha', sha, '--expect', first], { cwd });
  assert.equal(status, 0);
  assert.equal(git(remote, ['rev-parse', 'refs/heads/topic']), sha);
});

test('publish refuses when the remote head differs from expect', (t) => {
  const { repo, remote, sha, cwd } = setup(t);
  const first = git(repo, ['rev-parse', 'main~1']);
  git(repo, ['push', '-q', 'origin', `${sha}:refs/heads/topic`]);
  const other = commitFiles(repo, { 'b.txt': 'b\n' }, 'more');
  const { status, json } = runWfx(['publish', '--repo', repo, '--branch', 'topic', '--sha', other, '--expect', first], { cwd });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'lease-rejected');
  assert.equal(git(remote, ['rev-parse', 'refs/heads/topic']), sha);
});

test('publish rejects bad input with exit 2', (t) => {
  const { repo, sha, cwd } = setup(t);
  const base = ['publish', '--repo', repo];
  assert.equal(runWfx([...base, '--branch', 'topic', '--sha', 'abc', '--expect', 'none'], { cwd }).status, 2);
  assert.equal(runWfx([...base, '--branch', 'topic', '--sha', sha], { cwd }).status, 2);
  assert.equal(runWfx([...base, '--branch', '--evil', '--sha', sha, '--expect', 'none'], { cwd }).status, 2);
  assert.equal(runWfx([...base, '--branch', 'topic', '--sha', sha, '--expect', 'abc'], { cwd }).status, 2);
});

test('publish maps a remote hook rejection to push-rejected with stderr, not a lease failure', (t) => {
  const { repo, remote, sha, cwd } = setup(t);
  const hook = join(remote, 'hooks', 'pre-receive');
  writeFileSync(hook, '#!/bin/sh\necho protected branch >&2\nexit 1\n');
  chmodSync(hook, 0o755);
  const { status, json } = runWfx(['publish', '--repo', repo, '--branch', 'topic', '--sha', sha, '--expect', 'none'], { cwd });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'push-rejected');
  assert.match(json.error.details.stderr, /protected branch/);
});

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { bareRemote, commitFiles, fakeGh, pathWith, runWfx, tempDir, tempRepo } from './fx-kit.mjs';

function git(cwd, args) {
  const res = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(res.status, 0, `git ${args.join(' ')}: ${res.stderr}`);
  return res.stdout.trim();
}

// main has moved one commit past the feature branch base.
function movedBase(t) {
  const repo = tempRepo(t);
  const remote = bareRemote(repo, t);
  git(repo, ['checkout', '-q', '-b', 'feat']);
  commitFiles(repo, { 'feat.txt': 'feature\n' }, 'feature work');
  git(repo, ['push', '-q', 'origin', 'feat']);
  git(repo, ['checkout', '-q', 'main']);
  commitFiles(repo, { 'main2.txt': 'main moved\n' }, 'main moves');
  return { repo, remote };
}

const snapshot = (repo) => ({ head: git(repo, ['symbolic-ref', 'HEAD']), status: git(repo, ['status', '--porcelain']) });

test('restack rebases the branch and leaves the caller checkout alone', (t) => {
  const { repo } = movedBase(t);
  const before = snapshot(repo);
  const oldFeat = git(repo, ['rev-parse', 'feat']);
  const main = git(repo, ['rev-parse', 'main']);
  const { status, json } = runWfx(['restack', '--repo', repo, '--branch', 'feat', '--onto', 'main'], { cwd: tempDir(t) });
  assert.equal(status, 0, JSON.stringify(json));
  assert.equal(json.data.old, oldFeat);
  assert.equal(json.data.pushed, false);
  assert.notEqual(json.data.new, oldFeat);
  assert.equal(git(repo, ['rev-parse', 'feat']), json.data.new);
  assert.equal(git(repo, ['rev-parse', `${json.data.new}~1`]), main);
  assert.deepEqual(snapshot(repo), before);
  assert.equal(existsSync(join(repo, 'feat.txt')), false);
  assert.equal(git(repo, ['worktree', 'list', '--porcelain']).split('\n').filter((l) => l.startsWith('worktree ')).length, 1);
});

test('restack --push uses a lease and updates the remote branch', (t) => {
  const { repo, remote } = movedBase(t);
  const { status, json } = runWfx(['restack', '--repo', repo, '--branch', 'feat', '--onto', 'main', '--push'], { cwd: tempDir(t) });
  assert.equal(status, 0, JSON.stringify(json));
  assert.equal(json.data.pushed, true);
  assert.equal(git(remote, ['rev-parse', 'refs/heads/feat']), json.data.new);
});

test('restack --push refuses when someone else pushed to the remote branch', (t) => {
  const { repo, remote } = movedBase(t);
  const oldFeat = git(repo, ['rev-parse', 'feat']);
  // Another clone pushes a new commit to feat.
  const other = tempDir(t, 'wfx-other-');
  git(other, ['clone', '-q', remote, '.']);
  git(other, ['config', 'user.name', 'Other']);
  git(other, ['config', 'user.email', 'o@example.invalid']);
  git(other, ['checkout', '-q', 'feat']);
  const theirs = commitFiles(other, { 'other.txt': 'x\n' }, 'other work');
  git(other, ['push', '-q', 'origin', 'feat']);

  const { status, json } = runWfx(['restack', '--repo', repo, '--branch', 'feat', '--onto', 'main', '--push'], { cwd: tempDir(t) });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'lease-rejected');
  assert.equal(git(remote, ['rev-parse', 'refs/heads/feat']), theirs);
  assert.notEqual(oldFeat, theirs);
});

test('restack --expect pins the lease to the given SHA', (t) => {
  const { repo, remote } = movedBase(t);
  const base = git(repo, ['rev-parse', 'main~1']);
  const { status, json } = runWfx(
    ['restack', '--repo', repo, '--branch', 'feat', '--onto', 'main', '--push', '--expect', base],
    { cwd: tempDir(t) },
  );
  assert.equal(status, 1);
  assert.equal(json.error.code, 'lease-rejected');
  assert.notEqual(git(remote, ['rev-parse', 'refs/heads/feat']), base);
});

test('restack reports conflicts, aborts, and leaves the branch unchanged', (t) => {
  const repo = tempRepo(t);
  git(repo, ['checkout', '-q', '-b', 'feat']);
  commitFiles(repo, { 'README.md': 'feature edit\n' }, 'feat edits readme');
  git(repo, ['checkout', '-q', 'main']);
  commitFiles(repo, { 'README.md': 'main edit\n' }, 'main edits readme');
  const feat = git(repo, ['rev-parse', 'feat']);
  const before = snapshot(repo);
  const { status, json } = runWfx(['restack', '--repo', repo, '--branch', 'feat', '--onto', 'main'], { cwd: tempDir(t) });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'conflict');
  assert.deepEqual(json.error.details.files, ['README.md']);
  assert.equal(git(repo, ['rev-parse', 'feat']), feat);
  assert.deepEqual(snapshot(repo), before);
  assert.equal(git(repo, ['worktree', 'list', '--porcelain']).split('\n').filter((l) => l.startsWith('worktree ')).length, 1);
});

test('restack keeps the ref of a branch that a checkout holds', (t) => {
  const { repo } = movedBase(t);
  git(repo, ['checkout', '-q', 'feat']);
  const feat = git(repo, ['rev-parse', 'feat']);
  const { status, json } = runWfx(['restack', '--repo', repo, '--branch', 'feat', '--onto', 'main'], { cwd: tempDir(t) });
  assert.equal(status, 0, JSON.stringify(json));
  assert.equal(json.data.localUpdated, false);
  assert.notEqual(json.data.new, feat);
  assert.equal(git(repo, ['rev-parse', 'feat']), feat);
  assert.equal(git(repo, ['status', '--porcelain']), '');
});

test('restack rejects bad input', (t) => {
  const repo = tempRepo(t);
  assert.equal(runWfx(['restack', '--repo', repo, '--onto', 'main'], { cwd: repo }).status, 2);
  assert.equal(runWfx(['restack', '--repo', repo, '--branch', '-x', '--onto', 'main'], { cwd: repo }).status, 2);
  const missing = runWfx(['restack', '--repo', repo, '--branch', 'nope', '--onto', 'main'], { cwd: repo });
  assert.equal(missing.status, 1);
  assert.equal(missing.json.error.code, 'not-found');
});

test('restack --stack delegates to gh-stack-rebase and returns status and output', (t) => {
  const repo = tempRepo(t);
  bareRemote(repo, t);
  const { binDir, logPath } = fakeGh(
    {
      'repo view --json defaultBranchRef --jq .defaultBranchRef.name': { stdout: 'main\n' },
      'stack rebase': { stdout: 'rebased stack\n' },
    },
    t,
  );
  const env = { ...process.env, PATH: pathWith(binDir) };
  const { status, json } = runWfx(['restack', '--stack', '--repo', repo], { cwd: tempDir(t), env });
  assert.equal(status, 0, JSON.stringify(json));
  assert.equal(json.data.status, 0);
  assert.match(json.data.stdout, /rebased stack/);
  const calls = readFileSync(logPath, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.deepEqual(calls, [['repo', 'view', '--json', 'defaultBranchRef', '--jq', '.defaultBranchRef.name'], ['stack', 'rebase']]);
});

test('restack --stack reports a failing gh stack rebase', (t) => {
  const repo = tempRepo(t);
  bareRemote(repo, t);
  const { binDir } = fakeGh(
    {
      'repo view --json defaultBranchRef --jq .defaultBranchRef.name': { stdout: 'main\n' },
      'stack rebase': { stderr: 'boom', status: 3 },
    },
    t,
  );
  const env = { ...process.env, PATH: pathWith(binDir) };
  const { status, json } = runWfx(['restack', '--stack', '--repo', repo], { cwd: tempDir(t), env });
  assert.equal(status, 1);
  assert.equal(json.error.code, 'stack-rebase-failed');
  assert.equal(json.error.details.status, 3);
  assert.match(json.error.details.stderr, /boom/);
});

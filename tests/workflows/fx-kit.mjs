// Test kit for wfx. Later curds reuse these helpers.
// Each helper that makes temp dirs registers cleanup on the test context `t`.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const WFX = join(HERE, '..', '..', 'bin', 'wfx');

export function tempDir(t, prefix = 'wfx-') {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  t?.after(() => {
    spawnSync('chmod', ['-R', 'u+rwx', dir]);
    rmSync(dir, { recursive: true, force: true });
  });
  return dir;
}

function git(cwd, args) {
  const res = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(res.status, 0, `git ${args.join(' ')} failed: ${res.stderr}`);
  return res.stdout.trim();
}

export function tempRepo(t) {
  const repo = tempDir(t, 'wfx-repo-');
  git(repo, ['init', '-q', '-b', 'main']);
  git(repo, ['config', 'user.name', 'Wfx Test']);
  git(repo, ['config', 'user.email', 'wfx@example.invalid']);
  git(repo, ['config', 'commit.gpgsign', 'false']);
  commitFiles(repo, { 'README.md': 'init\n' }, 'initial commit');
  return repo;
}

export function commitFiles(repo, files, msg) {
  for (const [path, content] of Object.entries(files)) {
    const abs = join(repo, path);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content);
  }
  git(repo, ['add', '--', ...Object.keys(files)]);
  git(repo, ['commit', '-q', '-m', msg]);
  return git(repo, ['rev-parse', 'HEAD']);
}

export function bareRemote(repo, t) {
  const remote = tempDir(t, 'wfx-remote-');
  git(remote, ['init', '-q', '--bare', '-b', 'main']);
  git(repo, ['remote', 'add', 'origin', remote]);
  git(repo, ['push', '-q', 'origin', 'main']);
  return remote;
}

// Writes an executable `gh` that logs argv as one JSON line and replies from fixtures.
// fixtures: { 'auth status': { stdout, stderr, status } }, keyed by argv joined with spaces.
export function fakeGh(fixtures, t) {
  const dir = tempDir(t, 'wfx-gh-');
  const binDir = join(dir, 'bin');
  mkdirSync(binDir);
  const logPath = join(dir, 'gh.log');
  writeFileSync(join(dir, 'fixtures.json'), JSON.stringify(fixtures));
  const script = `#!/usr/bin/env node
const fs = require('node:fs');
const argv = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(logPath)}, JSON.stringify(argv) + '\\n');
const fixtures = JSON.parse(fs.readFileSync(${JSON.stringify(join(dir, 'fixtures.json'))}, 'utf8'));
const hit = fixtures[argv.join(' ')];
if (!hit) { process.stderr.write('no fixture'); process.exit(1); }
process.stdout.write(hit.stdout ?? '');
process.stderr.write(hit.stderr ?? '');
process.exit(hit.status ?? 0);
`;
  const path = join(binDir, 'gh');
  writeFileSync(path, script);
  chmodSync(path, 0o755);
  return { binDir, logPath };
}

// A directory that holds a `wfx` symlink to the real shim.
export function wfxBinDir(t) {
  const dir = tempDir(t, 'wfx-bin-');
  symlinkSync(WFX, join(dir, 'wfx'));
  return dir;
}

// Builds a PATH from directories that hold node and git plus the given extras.
export function pathWith(...extra) {
  const base = ['node', 'git'].map((tool) => {
    const res = spawnSync('which', [tool], { encoding: 'utf8' });
    return dirname(res.stdout.trim());
  });
  return [...extra, ...base].join(':');
}

export function runWfx(args, { cwd, env } = {}) {
  const res = spawnSync(WFX, args, {
    cwd,
    env: env ?? process.env,
    encoding: 'utf8',
  });
  const lines = res.stdout.split('\n').filter((l) => l.length > 0);
  assert.equal(lines.length, 1, `stdout must hold exactly one JSON line, got: ${JSON.stringify(res.stdout)}`);
  const json = JSON.parse(lines[0]);
  assert.equal(typeof json, 'object');
  assert.ok(json !== null && !Array.isArray(json), 'stdout must be one JSON object');
  return { status: res.status, json, stdout: res.stdout, stderr: res.stderr };
}

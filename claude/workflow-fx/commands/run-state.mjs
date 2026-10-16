// wfx run-state put  --landing <id> --key <k> [--file <f>]   (stdin when no --file)
// wfx run-state get  --landing <id> --key <k>
// wfx run-state list --landing <id>
// Files live at ${WFX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wfx}/<landing>/<key>.json.
import { mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { FxError, badInput } from '../lib/envelope.mjs';
import { parseFlags } from '../lib/flags.mjs';
import { assertId } from '../lib/ids.mjs';

function stateRoot(env) {
  if (env.WFX_STATE_DIR) return env.WFX_STATE_DIR;
  const base = env.XDG_STATE_HOME || join(env.HOME || homedir(), '.local', 'state');
  return join(base, 'wfx');
}

export async function run(argv, ctx) {
  const sub = argv[0];
  const { flags } = parseFlags(argv.slice(1), { value: ['landing', 'key', 'file'] });
  if (!['put', 'get', 'list'].includes(sub)) throw badInput('usage: wfx run-state put|get|list');
  if (!flags.landing) throw badInput('run-state needs --landing');
  const landing = assertId(flags.landing, 'landing');
  const dir = join(stateRoot(ctx.env), landing);

  if (sub === 'list') {
    let names = [];
    try {
      names = readdirSync(dir);
    } catch (err) {
      if (err.code !== 'ENOENT') throw err;
    }
    const keys = names.filter((n) => n.endsWith('.json')).map((n) => n.slice(0, -5)).sort();
    return { data: { landing, keys } };
  }

  if (!flags.key) throw badInput(`run-state ${sub} needs --key`);
  const key = assertId(flags.key, 'key');
  const path = join(dir, `${key}.json`);

  if (sub === 'get') {
    let text;
    try {
      text = readFileSync(path, 'utf8');
    } catch (err) {
      if (err.code === 'ENOENT') throw new FxError('not-found', `no state for ${landing}/${key}`, { landing, key });
      throw err;
    }
    return { data: { landing, key, value: JSON.parse(text) } };
  }

  const raw = flags.file ? readFileSync(resolve(ctx.cwd, flags.file), 'utf8') : readFileSync(0, 'utf8');
  let value;
  try {
    value = JSON.parse(raw);
  } catch (err) {
    throw badInput(`value is not valid JSON: ${err.message}`);
  }
  mkdirSync(dir, { recursive: true });
  const tmp = join(dir, `.${key}.${process.pid}.tmp`);
  writeFileSync(tmp, JSON.stringify(value));
  renameSync(tmp, path);
  return { data: { landing, key, path } };
}

#!/usr/bin/env node
// wfx <command> [args] — workflow effects tool.
// Commands live in commands/<command>.mjs and export run(argv, ctx).
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { badInput, emit, failureEnvelope, successEnvelope } from './lib/envelope.mjs';
import * as exec from './lib/exec.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const COMMAND_NAME = /^[a-z][a-z-]*$/;

async function main(argv) {
  const cmd = argv[0] ?? '';
  try {
    if (!COMMAND_NAME.test(cmd)) {
      throw badInput(cmd ? `invalid command name: ${cmd}` : 'usage: wfx <command> [args]');
    }
    const file = join(HERE, 'commands', `${cmd}.mjs`);
    if (!existsSync(file)) throw badInput(`unknown command: ${cmd}`);
    const mod = await import(pathToFileURL(file).href);
    const ctx = { cwd: process.cwd(), env: process.env, ...exec };
    const result = await mod.run(argv.slice(1), ctx);
    return emit(successEnvelope(cmd, result.data));
  } catch (err) {
    process.stderr.write(`wfx ${cmd}: ${err && err.message ? err.message : err}\n`);
    return emit(failureEnvelope(cmd, err));
  }
}

process.exitCode = await main(process.argv.slice(2));

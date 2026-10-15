// Loads digestOf from the shared prelude, so a test signs a state the way the workflows do.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { runInNewContext } from 'node:vm'

const prelude = readFileSync(fileURLToPath(new URL('../../claude/workflow-prelude/prelude.js', import.meta.url)), 'utf8')
export const { digestOf } = runInNewContext(`${prelude}\n({ digestOf })`, {})

// Small flag parser.
// spec: { value: [names], repeat: [names], bool: [names] } (names without dashes).
// Returns { flags, positionals }. Repeat flags always map to arrays.
import { badInput } from './envelope.mjs';

export function parseFlags(argv, spec = {}) {
  const value = new Set(spec.value ?? []);
  const repeat = new Set(spec.repeat ?? []);
  const bool = new Set(spec.bool ?? []);
  const flags = {};
  const positionals = [];
  for (const name of repeat) flags[name] = [];

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--') {
      positionals.push(...argv.slice(i + 1));
      break;
    }
    if (!arg.startsWith('--')) {
      positionals.push(arg);
      continue;
    }
    const eq = arg.indexOf('=');
    const name = eq === -1 ? arg.slice(2) : arg.slice(2, eq);
    if (bool.has(name)) {
      if (eq !== -1) throw badInput(`flag --${name} takes no value`);
      flags[name] = true;
    } else if (value.has(name) || repeat.has(name)) {
      let val;
      if (eq !== -1) {
        val = arg.slice(eq + 1);
      } else {
        if (i + 1 >= argv.length) throw badInput(`flag --${name} needs a value`);
        val = argv[++i];
      }
      if (repeat.has(name)) flags[name].push(val);
      else flags[name] = val;
    } else {
      throw badInput(`unknown flag --${name}`);
    }
  }
  return { flags, positionals };
}

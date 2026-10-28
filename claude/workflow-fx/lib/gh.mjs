// gh helpers shared by recon, poll, merge, and stamp.
import { FxError, badInput } from './envelope.mjs';

export function assertPr(value, label = 'pr') {
  if (typeof value !== 'string' || !/^[1-9][0-9]{0,8}$/.test(value)) {
    throw badInput(`--${label} must be a positive integer`);
  }
  return value;
}

// Runs gh and returns stdout. A failure becomes an FxError with the given code. input feeds gh's stdin.
export function ghOrThrow(ctx, args, code = 'gh-failed', input = undefined) {
  const res = ctx.gh(args, { env: ctx.env, cwd: ctx.cwd, input });
  if (res.status !== 0) {
    throw new FxError(code, `gh ${args.slice(0, 2).join(' ')} failed: ${res.stderr.trim()}`, {
      args,
      status: res.status,
      stderr: res.stderr.trim(),
    });
  }
  return res.stdout;
}

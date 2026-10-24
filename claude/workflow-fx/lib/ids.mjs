// Id check shared by worktree and run-state: landing ids, keys, and worktree names.
import { badInput } from './envelope.mjs';

export const ID_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;

export function assertId(value, label) {
  if (typeof value !== 'string' || !ID_RE.test(value)) {
    throw badInput(`${label} must match ${ID_RE}`);
  }
  return value;
}

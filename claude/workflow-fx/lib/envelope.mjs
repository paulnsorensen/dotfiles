// Envelope contract: one JSON object on stdout per invocation.
// Exit codes: 0 success, 1 operation failure, 2 bad input.

export class FxError extends Error {
  constructor(code, message, details) {
    super(message);
    this.name = 'FxError';
    this.code = code;
    this.details = details;
  }
}

export function badInput(message, details) {
  return new FxError('bad-input', message, details);
}

export function successEnvelope(cmd, data) {
  return { ok: true, cmd, data };
}

export function failureEnvelope(cmd, err) {
  const error = {
    code: err instanceof FxError ? err.code : 'internal',
    message: err && err.message ? err.message : String(err),
  };
  if (err instanceof FxError && err.details !== undefined) error.details = err.details;
  return { ok: false, cmd, error };
}

export function exitCodeFor(envelope) {
  if (envelope.ok) return 0;
  return envelope.error.code === 'bad-input' ? 2 : 1;
}

export function emit(envelope, stdout = process.stdout) {
  stdout.write(`${JSON.stringify(envelope)}\n`);
  return exitCodeFor(envelope);
}

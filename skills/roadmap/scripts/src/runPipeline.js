
/**
 * Orchestrates the /roadmap generator pipeline over injected capabilities.
 *
 * Every domain capability is optional-by-configuration (no Linear API key ->
 * no `fetchLinear`; no Notion config -> no `publish`). A missing optional
 * capability is reported by name in the returned `skipped` list (and via
 * `log`, when provided) — never silently dropped, never thrown for.
 * `readFile` is the one required capability: without it there is no sidecar
 * to build a model from, so its absence is a caller error, not a graceful
 * skip.
 *
 * Stage functions are injected rather than imported so this module has no
 * dependency on sibling curd files (fetchLinear.js, renderExec.js, ...); real
 * wiring of those implementations happens in cli.js.
 *
 * @typedef {Object} RunPipelineCapabilities
 * @property {() => Promise<import('./types.js').LinearModel>} [fetchLinear]
 * @property {(sidecarPath: string) => Promise<unknown>} readFile  reads (and parses) the sidecar config
 * @property {{
 *   renderExec: (model: unknown) => Promise<unknown>,
 *   renderLanes: (model: unknown) => Promise<unknown>,
 *   renderDag: (model: unknown) => Promise<unknown>,
 * }} [renderers]
 * @property {(outputs: Record<string, unknown>, sidecar: unknown) => Promise<unknown>} [publish]
 * @property {(message: string) => void} [log]
 */

/**
 * @param {string} sidecarPath
 * @param {RunPipelineCapabilities} capabilities
 * @returns {Promise<{outputs: Record<string, unknown>, skipped: {capability: string, reason: string}[]}>}
 */
export async function runPipeline(sidecarPath, capabilities) {
  const { fetchLinear, readFile, renderers, publish, log } = capabilities;

  if (typeof readFile !== 'function') {
    throw new Error('runPipeline requires a readFile capability to read the sidecar config');
  }

  const report = typeof log === 'function' ? log : () => {};
  const skipped = [];
  const outputs = {};

  const skip = (capability, reason) => {
    skipped.push({ capability, reason });
    report(`skipped ${capability}: ${reason}`);
  };

  const sidecar = await readFile(sidecarPath);

  let linear = null;
  if (typeof fetchLinear === 'function') {
    linear = await fetchLinear();
    outputs.linear = linear;
  } else {
    skip('linear', 'fetchLinear capability not provided (no Linear API key configured)');
  }

  const model = { sidecar, linear };

  if (renderers) {
    outputs.exec = await renderers.renderExec(model);
    outputs.lanes = await renderers.renderLanes(model);
    outputs.dag = await renderers.renderDag(model);
  } else {
    skip('renderers', 'renderers capability not provided (no renderer functions configured)');
  }

  if (typeof publish === 'function') {
    outputs.publish = await publish(outputs, sidecar);
  } else {
    skip('notion', 'publish capability not provided (no Notion configuration)');
  }

  return { outputs, skipped };
}

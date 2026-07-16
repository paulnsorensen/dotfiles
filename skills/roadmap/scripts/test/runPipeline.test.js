
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runPipeline } from '../src/runPipeline.js';

const sidecarModel = { subject: 'KIP', items: {} };

function makeRenderers() {
  const calls = [];
  return {
    calls,
    renderers: {
      renderExec: async (model) => {
        calls.push(['renderExec', model]);
        return { frame: 'exec' };
      },
      renderLanes: async (model) => {
        calls.push(['renderLanes', model]);
        return { frame: 'lanes' };
      },
      renderDag: async (model) => {
        calls.push(['renderDag', model]);
        return { png: 'dag.png' };
      },
    },
  };
}

test('missing Linear capability: skips linear by name, renderers still run on sidecar-only model', async () => {
  const logs = [];
  const { renderers, calls } = makeRenderers();

  const result = await runPipeline('/path/sidecar.yaml', {
    readFile: async () => sidecarModel,
    renderers,
    publish: async () => ({ notionPageUrl: 'https://notion.so/x' }),
    log: (message) => logs.push(message),
  });

  const linearSkip = result.skipped.find((entry) => entry.capability === 'linear');
  assert.ok(linearSkip, 'expected a skipped entry naming linear');
  assert.equal(result.skipped.length, 1);
  assert.ok(logs.some((line) => line.includes('linear')));

  assert.equal(calls.length, 3);
  for (const [, model] of calls) {
    assert.equal(model.linear, null);
    assert.deepEqual(model.sidecar, sidecarModel);
  }
  assert.deepEqual(result.outputs.exec, { frame: 'exec' });
  assert.deepEqual(result.outputs.lanes, { frame: 'lanes' });
  assert.deepEqual(result.outputs.dag, { png: 'dag.png' });
  assert.equal(result.outputs.linear, undefined);
});

test('missing Notion (publish) capability: skips notion by name, PNGs still produced', async () => {
  const { renderers } = makeRenderers();

  const result = await runPipeline('/path/sidecar.yaml', {
    fetchLinear: async () => ({ team: 'KIP', projects: [], initiatives: [], relations: [] }),
    readFile: async () => sidecarModel,
    renderers,
  });

  const notionSkip = result.skipped.find((entry) => entry.capability === 'notion');
  assert.ok(notionSkip, 'expected a skipped entry naming notion');
  assert.equal(result.skipped.length, 1);

  assert.deepEqual(result.outputs.dag, { png: 'dag.png' });
  assert.equal(result.outputs.publish, undefined);
});

test('all capabilities present: no skipped entries', async () => {
  const { renderers } = makeRenderers();

  const result = await runPipeline('/path/sidecar.yaml', {
    fetchLinear: async () => ({ team: 'KIP', projects: [], initiatives: [], relations: [] }),
    readFile: async () => sidecarModel,
    renderers,
    publish: async () => ({ notionPageUrl: 'https://notion.so/x' }),
  });

  assert.deepEqual(result.skipped, []);
  assert.ok(result.outputs.linear);
  assert.deepEqual(result.outputs.exec, { frame: 'exec' });
  assert.deepEqual(result.outputs.lanes, { frame: 'lanes' });
  assert.deepEqual(result.outputs.dag, { png: 'dag.png' });
  assert.deepEqual(result.outputs.publish, { notionPageUrl: 'https://notion.so/x' });
});

test('missing readFile capability throws (required, not optional-by-capability)', async () => {
  await assert.rejects(() => runPipeline('/path/sidecar.yaml', {}));
});

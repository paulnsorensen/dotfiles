import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { fixtureModel } from './fixtures/roadmapModel.js';
import { layoutDag, renderDag } from '../src/renderDag.js';

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

// The fixture's 'dashboards' item carries altitudes [1, 2] — the altitude-3
// DAG must exclude it, and with it every edge touching it.
const altitude3Items = fixtureModel.items.filter((item) => item.altitudes.includes(3));

test('layoutDag returns a node per altitude-3 item only', async () => {
  const graph = await layoutDag(fixtureModel);

  assert.equal(graph.children.length, altitude3Items.length);
  const nodeIds = graph.children.map((node) => node.id).sort();
  const itemRefs = altitude3Items.map((item) => item.ref).sort();
  assert.deepEqual(nodeIds, itemRefs);
  for (const node of graph.children) {
    assert.equal(typeof node.x, 'number');
    assert.equal(typeof node.y, 'number');
  }
});

test('layoutDag keeps only edges between altitude-3 items', async () => {
  const graph = await layoutDag(fixtureModel);

  // schema-registry->dashboards is dropped because dashboards is not tagged
  // for altitude 3; the linear ingest edge survives.
  const edgePairs = graph.edges.map((edge) => `${edge.sources[0]}->${edge.targets[0]}`);
  assert.deepEqual(edgePairs, ['ingest-api->extraction-v2']);
});

test('layoutDag excludes altitude-excluded items and their edges (altitude exclusion)', async () => {
  const graph = await layoutDag(fixtureModel);

  assert.ok(
    !graph.children.some((node) => node.id === 'dashboards'),
    'dashboards (altitudes [1, 2]) must not appear in the altitude-3 DAG',
  );
  assert.ok(
    !graph.edges.some((edge) => edge.sources.includes('dashboards') || edge.targets.includes('dashboards')),
    'no edge may reference the altitude-excluded dashboards item',
  );
});

test('renderDag resolves to a non-empty PNG buffer', async () => {
  const png = await renderDag(fixtureModel);

  assert.ok(Buffer.isBuffer(png));
  assert.ok(png.length > 0);
  assert.deepEqual(png.subarray(0, PNG_MAGIC.length), PNG_MAGIC);
});

test('renderDag falls back to plain SVG when the font loader fails', async () => {
  const png = await renderDag(fixtureModel, {
    loadFont: async () => {
      throw new Error('no font available');
    },
  });

  assert.ok(Buffer.isBuffer(png));
  assert.ok(png.length > 0);
  assert.deepEqual(png.subarray(0, PNG_MAGIC.length), PNG_MAGIC);
});

test('renderDag accepts an injected font loader', async () => {
  const fontPath = '/System/Library/Fonts/Supplemental/Arial.ttf';
  const fontData = await readFile(fontPath).catch(() => null);
  if (!fontData) {
    // Environment has no Arial.ttf to inject; the default-loader coverage above still holds.
    return;
  }

  const png = await renderDag(fixtureModel, { loadFont: async () => fontData });

  assert.ok(Buffer.isBuffer(png));
  assert.deepEqual(png.subarray(0, PNG_MAGIC.length), PNG_MAGIC);
});

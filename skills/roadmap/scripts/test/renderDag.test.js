import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { fixtureModel } from './fixtures/roadmapModel.js';
import { layoutDag, renderDag } from '../src/renderDag.js';

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

test('layoutDag returns a node per item', async () => {
  const graph = await layoutDag(fixtureModel);

  assert.equal(graph.children.length, fixtureModel.items.length);
  const nodeIds = graph.children.map((node) => node.id).sort();
  const itemRefs = fixtureModel.items.map((item) => item.ref).sort();
  assert.deepEqual(nodeIds, itemRefs);
  for (const node of graph.children) {
    assert.equal(typeof node.x, 'number');
    assert.equal(typeof node.y, 'number');
  }
});

test('layoutDag returns exactly the fixture deduped edges', async () => {
  const graph = await layoutDag(fixtureModel);

  assert.equal(graph.edges.length, fixtureModel.edges.length);
  const edgePairs = graph.edges
    .map((edge) => `${edge.sources[0]}->${edge.targets[0]}`)
    .sort();
  const expectedPairs = fixtureModel.edges
    .map((edge) => `${edge.sourceRef}->${edge.targetRef}`)
    .sort();
  assert.deepEqual(edgePairs, expectedPairs);
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

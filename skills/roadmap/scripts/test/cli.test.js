
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { buildCapabilities } from '../src/cli.js';

const SIDECAR_MINIMAL = 'subject: KIP\nbuckets: quarters\n';
const SIDECAR_WITH_NOTION = 'subject: KIP\nbuckets: quarters\nnotion:\n  page: fixture-page-id\n';

test('fetchLinear capability is absent without LINEAR_API_KEY', () => {
  const { capabilities } = buildCapabilities({ env: {}, sidecarText: SIDECAR_MINIMAL });
  assert.equal(capabilities.fetchLinear, undefined);
});

test('fetchLinear capability is present with LINEAR_API_KEY', () => {
  const { capabilities } = buildCapabilities({
    env: { LINEAR_API_KEY: 'lin_test' },
    sidecarText: SIDECAR_MINIMAL,
  });
  assert.equal(typeof capabilities.fetchLinear, 'function');
});

test('publish capability requires both NOTION_API_KEY and sidecar notion.page', () => {
  const withKey = { NOTION_API_KEY: 'secret' };

  assert.equal(
    buildCapabilities({ env: withKey, sidecarText: SIDECAR_MINIMAL }).capabilities.publish,
    undefined,
  );
  assert.equal(
    buildCapabilities({ env: {}, sidecarText: SIDECAR_WITH_NOTION }).capabilities.publish,
    undefined,
  );
  assert.equal(
    typeof buildCapabilities({ env: withKey, sidecarText: SIDECAR_WITH_NOTION }).capabilities.publish,
    'function',
  );
});

test('wiring skips name the bookmark and image gaps when publish is wired', () => {
  const { skipped } = buildCapabilities({
    env: { NOTION_API_KEY: 'secret' },
    sidecarText: SIDECAR_WITH_NOTION,
  });

  assert.deepEqual(
    skipped.map((entry) => entry.capability),
    ['notion-bookmark', 'notion-images'],
  );
  for (const entry of skipped) {
    assert.ok(entry.reason.length > 0, `expected a reason on ${entry.capability}`);
  }
});

test('no wiring skips when publish is not wired', () => {
  const { skipped } = buildCapabilities({ env: {}, sidecarText: SIDECAR_MINIMAL });
  assert.deepEqual(skipped, []);
});

test('readFile capability returns the raw sidecar text', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'roadmap-cli-'));
  const file = join(dir, 'sidecar.yaml');
  await writeFile(file, SIDECAR_MINIMAL, 'utf8');

  const { capabilities } = buildCapabilities({ env: {}, sidecarText: SIDECAR_MINIMAL });
  assert.equal(await capabilities.readFile(file), SIDECAR_MINIMAL);

  await rm(dir, { recursive: true, force: true });
});

test('renderer capabilities build the RoadmapModel from raw YAML and null linear', async () => {
  const { capabilities } = buildCapabilities({ env: {}, sidecarText: SIDECAR_MINIMAL });
  const model = { sidecar: SIDECAR_MINIMAL, linear: null };

  const exec = await capabilities.renderers.renderExec(model);
  assert.equal(typeof exec.frameName, 'string');
  assert.ok(Array.isArray(exec.elements));

  const lanes = await capabilities.renderers.renderLanes(model);
  assert.ok(Array.isArray(lanes.elements));
});

test('renderers build the RoadmapModel once per pipeline model', async () => {
  const { capabilities } = buildCapabilities({ env: {}, sidecarText: SIDECAR_MINIMAL });
  let sidecarReads = 0;
  const model = {
    linear: null,
    get sidecar() {
      sidecarReads += 1;
      return SIDECAR_MINIMAL;
    },
  };

  await capabilities.renderers.renderExec(model);
  await capabilities.renderers.renderLanes(model);

  assert.equal(sidecarReads, 1);
});

test('publish capability appends to the sidecar notion page with no bookmark and no images', async () => {
  const appendCalls = [];
  const notionClient = {
    blocks: {
      children: {
        append: async (args) => {
          appendCalls.push(args);
          return { object: 'list', results: [] };
        },
      },
    },
  };

  const { capabilities } = buildCapabilities({
    env: { NOTION_API_KEY: 'secret' },
    sidecarText: SIDECAR_WITH_NOTION,
    createNotionClient: () => notionClient,
  });

  await capabilities.publish({ dag: Buffer.from('png-bytes') }, SIDECAR_WITH_NOTION);

  assert.equal(appendCalls.length, 1);
  assert.equal(appendCalls[0].block_id, 'fixture-page-id');
  assert.deepEqual(
    appendCalls[0].children.map((child) => child.type),
    ['heading_2'],
  );
});

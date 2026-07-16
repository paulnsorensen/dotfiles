import assert from 'node:assert/strict';
import { test } from 'node:test';

import { mergeSidecar } from '../src/mergeSidecar.js';
import { fixtureModel, fixtureRawEdges } from './fixtures/roadmapModel.js';

/**
 * LinearModel that, merged with the matching sidecar YAML below, reproduces
 * fixtureModel exactly. Dates are chosen so each project's startDate/targetDate
 * span lands in the quarters fixtureModel expects (see test/fixtures/roadmapModel.js
 * header comment for the properties this exercises: dedupe, fallback edges,
 * per-item altitudes, milestone dates).
 */
const linearModel = {
  team: 'KIP',
  initiatives: [
    { id: 'ingest', title: 'Ingest' },
    { id: 'structured-data', title: 'Structured Data' },
  ],
  projects: [
    {
      ref: 'ingest-api',
      title: 'Ingest API hardening',
      initiativeId: 'ingest',
      status: 'started',
      startDate: '2026-07-01',
      targetDate: '2026-09-30',
      milestones: [],
    },
    {
      ref: 'extraction-v2',
      title: 'Extraction pipeline v2',
      initiativeId: 'ingest',
      status: 'planned',
      startDate: '2026-08-01',
      targetDate: '2026-11-30',
      milestones: [{ id: 'm1', title: 'First extractor migrated', date: '2026-11-15' }],
    },
    {
      ref: 'schema-registry',
      title: 'Schema registry',
      initiativeId: 'structured-data',
      status: 'planned',
      startDate: '2026-10-01',
      targetDate: '2026-12-31',
      milestones: [{ id: 'm2', title: 'Registry API frozen', date: null }],
    },
    {
      ref: 'dashboards',
      title: 'Leadership dashboards',
      initiativeId: 'structured-data',
      status: 'planned',
      startDate: '2027-01-01',
      targetDate: '2027-03-31',
      milestones: [],
    },
  ],
  relations: [{ sourceRef: 'ingest-api', targetRef: 'extraction-v2', type: 'blocks' }],
};

const sidecarYaml = `
subject: KIP
buckets: quarters
items:
  ingest-api:
    unlocks:
      - Partners can push artifacts without manual review
    blocks:
      - extraction-v2
  extraction-v2:
    unlocks:
      - Facts land within an hour of ingest
  schema-registry:
    unlocks:
      - Teams declare structured data without KIP code changes
    blocks:
      - dashboards
  dashboards:
    unlocks:
      - Leadership reads roadmap state without asking
    altitude: [1, 2]
outcomes:
  - title: Ingest is self-serve
    horizon: now
    items: [ingest-api, extraction-v2]
  - title: Structured data is declarative
    horizon: next
    items: [schema-registry]
  - title: Roadmap reads itself
    horizon: later
    items: [dashboards]
notion:
  page: fixture-page-id
`;

test('mergeSidecar reproduces fixtureModel from Linear + sidecar YAML', () => {
  const result = mergeSidecar(linearModel, sidecarYaml);
  assert.deepEqual(result, fixtureModel);
});

test('mergeSidecar dedupes edges preferring the linear-sourced copy', () => {
  const result = mergeSidecar(linearModel, sidecarYaml);
  // the raw union mergeSidecar must reconcile before dedupe is exactly
  // fixtureRawEdges (linear duplicate + sidecar duplicate + sidecar fallback)
  const rawKinds = fixtureRawEdges.map((edge) => `${edge.sourceRef}->${edge.targetRef}:${edge.source}`);
  assert.deepEqual(rawKinds, [
    'ingest-api->extraction-v2:linear',
    'ingest-api->extraction-v2:sidecar',
    'schema-registry->dashboards:sidecar',
  ]);
  assert.deepEqual(result.edges, fixtureModel.edges);
  assert.equal(result.edges.length, 2);
  assert.equal(result.edges[0].source, 'linear');
});

test('sidecar item.lane overrides the initiative-derived laneId', () => {
  const yaml = `
subject: KIP
buckets: quarters
items:
  ingest-api:
    lane: special-lane
`;
  const result = mergeSidecar(linearModel, yaml);
  const item = result.items.find((it) => it.ref === 'ingest-api');
  assert.equal(item.laneId, 'special-lane');
  const other = result.items.find((it) => it.ref === 'extraction-v2');
  assert.equal(other.laneId, 'ingest');
});

test('explicit sidecar lanes replace initiative-derived lanes and remap via initiative', () => {
  const yaml = `
subject: KIP
buckets: quarters
lanes:
  - id: lane-a
    title: Lane A
    initiative: ingest
  - id: lane-b
    initiative: structured-data
`;
  const result = mergeSidecar(linearModel, yaml);
  assert.deepEqual(result.lanes, [
    { id: 'lane-a', title: 'Lane A' },
    { id: 'lane-b', title: 'lane-b' },
  ]);
  assert.equal(result.items.find((it) => it.ref === 'ingest-api').laneId, 'lane-a');
  assert.equal(result.items.find((it) => it.ref === 'schema-registry').laneId, 'lane-b');
});

test('minimal sidecar config applies defaults: altitudes, unlocks, outcomes, notion', () => {
  const yaml = `
subject: KIP
buckets: quarters
`;
  const result = mergeSidecar(linearModel, yaml);
  assert.deepEqual(result.outcomes, []);
  assert.equal(result.notion, null);
  for (const item of result.items) {
    assert.deepEqual(item.altitudes, [1, 2, 3]);
    assert.deepEqual(item.unlocks, []);
  }
});

test('buckets: cycles maps project dates to 14-day cycle ids instead of quarters', () => {
  const yaml = `
subject: KIP
buckets: cycles
`;
  const result = mergeSidecar(linearModel, yaml);
  const ingestApi = result.items.find((it) => it.ref === 'ingest-api');
  assert.ok(ingestApi.bucketIds.every((id) => /^C\d+$/.test(id)));
  assert.ok(result.buckets.every((bucket) => /^C\d+$/.test(bucket.id)));
  // buckets are ordered ascending by cycle index, not lexically
  const orders = result.buckets.map((bucket) => Number(bucket.id.slice(1)));
  assert.deepEqual(orders, [...orders].sort((a, b) => a - b));
});

test('a project with no dates gets an empty bucketIds list', () => {
  const model = {
    ...linearModel,
    projects: [
      {
        ref: 'undated',
        title: 'Undated project',
        initiativeId: 'ingest',
        status: 'planned',
        startDate: null,
        targetDate: null,
        milestones: [],
      },
    ],
  };
  const result = mergeSidecar(model, 'subject: KIP\nbuckets: quarters\n');
  assert.deepEqual(result.items[0].bucketIds, []);
});

test('throws naming the offending field path for an unknown top-level key', () => {
  const yaml = 'subject: KIP\nbuckets: quarters\nbogus: true\n';
  assert.throws(() => mergeSidecar(linearModel, yaml), /\$\.bogus/);
});

test('throws naming the offending field path for an unknown item field', () => {
  const yaml = `
subject: KIP
buckets: quarters
items:
  ingest-api:
    status: started
`;
  assert.throws(() => mergeSidecar(linearModel, yaml), /items\.ingest-api\.status/);
});

test('throws for an invalid buckets enum value', () => {
  const yaml = 'subject: KIP\nbuckets: sprints\n';
  assert.throws(() => mergeSidecar(linearModel, yaml), /"buckets"/);
});

test('throws for an out-of-range altitude value', () => {
  const yaml = `
subject: KIP
buckets: quarters
items:
  ingest-api:
    altitude: [1, 4]
`;
  assert.throws(() => mergeSidecar(linearModel, yaml), /items\.ingest-api\.altitude\[1\]/);
});

test('throws for a missing required subject field', () => {
  const yaml = 'buckets: quarters\n';
  assert.throws(() => mergeSidecar(linearModel, yaml), /"subject"/);
});

test('throws for an unknown lane field and does not return a partial result', () => {
  const yaml = `
subject: KIP
buckets: quarters
lanes:
  - id: lane-a
    initiative: ingest
    color: red
`;
  assert.throws(() => mergeSidecar(linearModel, yaml), /lanes\[0\]\.color/);
});

test('throws for an unknown outcome field', () => {
  const yaml = `
subject: KIP
buckets: quarters
outcomes:
  - title: Foo
    horizon: now
    items: [ingest-api]
    priority: 1
`;
  assert.throws(() => mergeSidecar(linearModel, yaml), /outcomes\[0\]\.priority/);
});

test('throws for an invalid outcome horizon', () => {
  const yaml = `
subject: KIP
buckets: quarters
outcomes:
  - title: Foo
    horizon: soon
    items: [ingest-api]
`;
  assert.throws(() => mergeSidecar(linearModel, yaml), /outcomes\[0\]\.horizon/);
});

test('throws for an unknown notion field', () => {
  const yaml = `
subject: KIP
buckets: quarters
notion:
  page: abc
  workspace: xyz
`;
  assert.throws(() => mergeSidecar(linearModel, yaml), /notion\.workspace/);
});

test('empty sidecar text fails validation on the missing subject, not with a crash', () => {
  assert.throws(() => mergeSidecar(linearModel, ''), /"subject": missing required field/);
});

test('throws for a non-string subject value', () => {
  assert.throws(() => mergeSidecar(linearModel, 'subject: 5\nbuckets: quarters\n'), /"subject": expected string, got number/);
});

test('a project with targetDate before startDate gets empty bucketIds and adds no buckets', () => {
  const model = {
    ...linearModel,
    projects: [
      {
        ref: 'inverted',
        title: 'Inverted dates',
        initiativeId: 'ingest',
        status: 'planned',
        startDate: '2026-12-01',
        targetDate: '2026-07-01',
        milestones: [],
      },
    ],
  };
  const result = mergeSidecar(model, 'subject: KIP\nbuckets: quarters\n');
  assert.deepEqual(result.items[0].bucketIds, []);
  assert.deepEqual(result.buckets, []);
});

test('a project with only one of startDate/targetDate maps to the single bucket of that date', () => {
  const model = {
    ...linearModel,
    projects: [
      {
        ref: 'target-only',
        title: 'Target only',
        initiativeId: 'ingest',
        status: 'planned',
        startDate: null,
        targetDate: '2026-08-15',
        milestones: [],
      },
      {
        ref: 'start-only',
        title: 'Start only',
        initiativeId: 'ingest',
        status: 'planned',
        startDate: '2027-02-01',
        targetDate: null,
        milestones: [],
      },
    ],
  };
  const result = mergeSidecar(model, 'subject: KIP\nbuckets: quarters\n');
  assert.deepEqual(result.items[0].bucketIds, ['2026-Q3']);
  assert.deepEqual(result.items[1].bucketIds, ['2027-Q1']);
});

test('a sidecar item keyed by a ref unknown to Linear creates no phantom item; its blocks edge joins the union', () => {
  const yaml = `
subject: KIP
buckets: quarters
items:
  ghost:
    blocks: [ingest-api]
`;
  const result = mergeSidecar(linearModel, yaml);
  assert.deepEqual(
    result.items.map((item) => item.ref).sort(),
    linearModel.projects.map((project) => project.ref).sort(),
  );
  assert.ok(
    result.edges.some((edge) => edge.sourceRef === 'ghost' && edge.targetRef === 'ingest-api' && edge.source === 'sidecar'),
    'dangling sidecar blocks edge stays in the union (altitudeFilter drops it downstream)',
  );
});

test('dedupe is direction-sensitive: a sidecar edge reversing a linear edge is kept, not deduped', () => {
  const yaml = `
subject: KIP
buckets: quarters
items:
  extraction-v2:
    blocks: [ingest-api]
`;
  const result = mergeSidecar(linearModel, yaml);
  const pairs = result.edges.map((edge) => `${edge.sourceRef}->${edge.targetRef}:${edge.source}`);
  assert.ok(pairs.includes('ingest-api->extraction-v2:linear'));
  assert.ok(pairs.includes('extraction-v2->ingest-api:sidecar'));
});

test('source files contain no raw control bytes (a raw NUL once made git treat mergeSidecar.js as binary)', async () => {
  const { readdir, readFile } = await import('node:fs/promises');
  const { join } = await import('node:path');
  const srcDir = new URL('../src/', import.meta.url).pathname;
  for (const name of await readdir(srcDir)) {
    const buf = await readFile(join(srcDir, name));
    const bad = buf.findIndex((byte) => byte < 0x09 || (byte > 0x0d && byte < 0x20));
    assert.equal(bad, -1, `${name} contains raw control byte 0x${buf[bad]?.toString(16)} at offset ${bad}`);
  }
});

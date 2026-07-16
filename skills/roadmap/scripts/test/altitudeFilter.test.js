
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { filterByAltitude } from '../src/altitudeFilter.js';
import { fixtureModel } from './fixtures/roadmapModel.js';

test('altitude 3 excludes items scoped to altitudes [1, 2] only', () => {
  const result = filterByAltitude(fixtureModel, 3);

  const refs = result.items.map((item) => item.ref);
  assert.equal(refs.includes('dashboards'), false);
  assert.deepEqual(refs, ['ingest-api', 'extraction-v2', 'schema-registry']);
});

test('altitude 3 drops edges that touch an excluded item', () => {
  const result = filterByAltitude(fixtureModel, 3);

  const edgeRefs = result.edges.map((edge) => `${edge.sourceRef}->${edge.targetRef}`);
  assert.equal(edgeRefs.includes('schema-registry->dashboards'), false);
  assert.deepEqual(edgeRefs, ['ingest-api->extraction-v2']);
});

test('altitude 3 filters outcome member lists and drops emptied outcomes', () => {
  const result = filterByAltitude(fixtureModel, 3);

  const titles = result.outcomes.map((outcome) => outcome.title);
  assert.equal(titles.includes('Roadmap reads itself'), false);
  assert.deepEqual(titles, ['Ingest is self-serve', 'Structured data is declarative']);
});

test('altitude 1 keeps dashboards, its edge, and its outcome', () => {
  const result = filterByAltitude(fixtureModel, 1);

  assert.ok(result.items.some((item) => item.ref === 'dashboards'));
  assert.ok(
    result.edges.some(
      (edge) => edge.sourceRef === 'schema-registry' && edge.targetRef === 'dashboards',
    ),
  );
  assert.ok(result.outcomes.some((outcome) => outcome.title === 'Roadmap reads itself'));
});

test('altitude 2 keeps dashboards, its edge, and its outcome', () => {
  const result = filterByAltitude(fixtureModel, 2);

  assert.ok(result.items.some((item) => item.ref === 'dashboards'));
  assert.ok(
    result.edges.some(
      (edge) => edge.sourceRef === 'schema-registry' && edge.targetRef === 'dashboards',
    ),
  );
  assert.ok(result.outcomes.some((outcome) => outcome.title === 'Roadmap reads itself'));
});

test('items with no altitudes array default to appearing at every altitude', () => {
  const noAltitudesModel = {
    ...fixtureModel,
    items: [{ ...fixtureModel.items[0], altitudes: undefined }],
    edges: [],
    outcomes: [],
  };

  for (const altitude of [1, 2, 3]) {
    const result = filterByAltitude(noAltitudesModel, altitude);
    assert.equal(result.items.length, 1);
  }
});

test('does not mutate the input model', () => {
  const before = JSON.parse(JSON.stringify(fixtureModel));

  filterByAltitude(fixtureModel, 3);

  assert.deepEqual(fixtureModel, before);
});

test('preserves non-filtered model fields unchanged', () => {
  const result = filterByAltitude(fixtureModel, 3);

  assert.equal(result.subject, fixtureModel.subject);
  assert.deepEqual(result.buckets, fixtureModel.buckets);
  assert.deepEqual(result.lanes, fixtureModel.lanes);
  assert.deepEqual(result.notion, fixtureModel.notion);
});

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { renderLanes, FRAME_NAME, LANE_GEOMETRY } from '../src/renderLanes.js';
import { fixtureModel } from './fixtures/roadmapModel.js';

function byKind(elements, kind) {
  return elements.filter((element) => element.customData?.kind === kind);
}

test('returns the altitude-2 frame name', () => {
  const { frameName } = renderLanes(fixtureModel);
  assert.equal(frameName, FRAME_NAME);
  assert.equal(frameName, 'Altitude 2 — Workstreams');
});

test('renders exactly one lane band and title per model.lanes entry', () => {
  const { elements } = renderLanes(fixtureModel);
  const laneBands = byKind(elements, 'laneBand');
  const laneTitles = byKind(elements, 'laneTitle');

  assert.equal(laneBands.length, fixtureModel.lanes.length);
  assert.equal(laneTitles.length, fixtureModel.lanes.length);

  fixtureModel.lanes.forEach((lane, laneIndex) => {
    const band = laneBands.find((element) => element.customData.laneId === lane.id);
    const title = laneTitles.find((element) => element.customData.laneId === lane.id);
    assert.ok(band, `expected a lane band for ${lane.id}`);
    assert.ok(title, `expected a lane title for ${lane.id}`);
    assert.equal(title.text, lane.title);

    const expectedY = LANE_GEOMETRY.bucketHeaderHeight + laneIndex * LANE_GEOMETRY.laneHeight;
    assert.equal(band.y, expectedY);
    assert.equal(band.height, LANE_GEOMETRY.laneHeight);
    assert.equal(band.type, 'rectangle');
  });
});

test('renders one bucket band + label per model.buckets entry, as fixed columns not a date axis', () => {
  const { elements } = renderLanes(fixtureModel);
  const bucketBands = byKind(elements, 'bucketBand');
  const bucketLabels = byKind(elements, 'bucketLabel');

  assert.equal(bucketBands.length, fixtureModel.buckets.length);
  assert.equal(bucketLabels.length, fixtureModel.buckets.length);

  fixtureModel.buckets.forEach((bucket, bucketIndex) => {
    const band = bucketBands.find((element) => element.customData.bucketId === bucket.id);
    const label = bucketLabels.find((element) => element.customData.bucketId === bucket.id);
    assert.ok(band, `expected a bucket band for ${bucket.id}`);
    assert.equal(label.text, bucket.label);

    const expectedX = LANE_GEOMETRY.laneHeaderWidth + bucketIndex * LANE_GEOMETRY.bucketWidth;
    assert.equal(band.x, expectedX);
    assert.equal(band.width, LANE_GEOMETRY.bucketWidth);
  });
});

test('item bars land in the correct lane row and bucket column span', () => {
  const { elements } = renderLanes(fixtureModel);
  const itemBars = byKind(elements, 'itemBar');

  assert.equal(itemBars.length, fixtureModel.items.length);

  fixtureModel.items.forEach((item) => {
    const bar = itemBars.find((element) => element.customData.itemRef === item.ref);
    assert.ok(bar, `expected an item bar for ${item.ref}`);
    assert.equal(bar.type, 'rectangle');

    const laneIndex = fixtureModel.lanes.findIndex((lane) => lane.id === item.laneId);
    const laneY = LANE_GEOMETRY.bucketHeaderHeight + laneIndex * LANE_GEOMETRY.laneHeight;
    assert.ok(bar.y >= laneY, `${item.ref} bar should start within its lane row`);
    assert.ok(
      bar.y + bar.height <= laneY + LANE_GEOMETRY.laneHeight,
      `${item.ref} bar should stay within its lane row`,
    );

    const bucketIndices = item.bucketIds.map((bucketId) =>
      fixtureModel.buckets.findIndex((bucket) => bucket.id === bucketId),
    );
    const startIndex = Math.min(...bucketIndices);
    const endIndex = Math.max(...bucketIndices);
    const columnStart = LANE_GEOMETRY.laneHeaderWidth + startIndex * LANE_GEOMETRY.bucketWidth;
    const columnEnd = LANE_GEOMETRY.laneHeaderWidth + (endIndex + 1) * LANE_GEOMETRY.bucketWidth;

    assert.ok(bar.x >= columnStart, `${item.ref} bar should not start before its first bucket`);
    assert.ok(bar.x + bar.width <= columnEnd, `${item.ref} bar should not extend past its last bucket`);
    assert.deepEqual(bar.customData.bucketIds, item.bucketIds);
  });
});

test('items sharing a lane get non-overlapping sub-rows', () => {
  const { elements } = renderLanes(fixtureModel);
  const itemBars = byKind(elements, 'itemBar');

  const ingestBars = itemBars.filter((bar) => bar.customData.laneId === 'ingest');
  assert.equal(ingestBars.length, 2);
  const [first, second] = [...ingestBars].sort((a, b) => a.y - b.y);
  assert.ok(first.y + first.height <= second.y, 'ingest lane bars should not overlap vertically');
});

test('milestone verticals render only for milestones with a date', () => {
  const { elements } = renderLanes(fixtureModel);
  const milestoneLines = byKind(elements, 'milestone');
  const milestoneLabels = byKind(elements, 'milestoneLabel');

  const datedMilestones = fixtureModel.items.flatMap((item) =>
    item.milestones.filter((milestone) => milestone.date).map((milestone) => ({ item, milestone })),
  );

  assert.equal(milestoneLines.length, datedMilestones.length);
  assert.equal(milestoneLabels.length, datedMilestones.length);

  // fixture: only extraction-v2's m1 has a date; schema-registry's m2 (date: null) must be absent
  assert.equal(datedMilestones.length, 1);
  assert.equal(datedMilestones[0].milestone.id, 'm1');
  assert.equal(milestoneLines[0].customData.itemRef, 'extraction-v2');
  assert.equal(milestoneLines[0].customData.milestoneId, 'm1');
  assert.ok(!milestoneLines.some((line) => line.customData.milestoneId === 'm2'));

  const label = milestoneLabels.find((element) => element.customData.milestoneId === 'm1');
  assert.equal(label.text, 'First extractor migrated');

  // the milestone date (2026-11-15) falls in bucket 2026-Q4, which extraction-v2 spans
  const line = milestoneLines[0];
  assert.equal(line.customData.bucketId, '2026-Q4');
  const bar = byKind(elements, 'itemBar').find((element) => element.customData.itemRef === 'extraction-v2');
  assert.ok(line.x >= bar.x && line.x + line.width <= bar.x + bar.width, 'milestone should land within its item bar');
});

test('is a pure function: repeat calls over the same model produce identical output', () => {
  const first = renderLanes(fixtureModel);
  const second = renderLanes(fixtureModel);
  assert.deepEqual(first, second);
});

test('every element is well-formed Excalidraw shape/text data', () => {
  const { elements } = renderLanes(fixtureModel);
  assert.ok(elements.length > 0);
  for (const element of elements) {
    assert.ok(['rectangle', 'text'].includes(element.type));
    assert.equal(typeof element.id, 'string');
    assert.equal(typeof element.x, 'number');
    assert.equal(typeof element.y, 'number');
    assert.equal(typeof element.width, 'number');
    assert.equal(typeof element.height, 'number');
    assert.equal(element.isDeleted, false);
    if (element.type === 'text') {
      assert.equal(typeof element.text, 'string');
    }
  }
});

test('excludes items not tagged for altitude 2', () => {
  // Altitude exclusion: an item whose altitudes omit 2 must never reach the
  // workstream swimlanes — no bar and no label for it.
  const model = {
    ...fixtureModel,
    items: fixtureModel.items.map((item) =>
      item.ref === 'dashboards' ? { ...item, altitudes: [1, 3] } : item,
    ),
  };

  const { elements } = renderLanes(model);
  const itemBars = byKind(elements, 'itemBar');
  const itemLabels = byKind(elements, 'itemLabel');

  assert.equal(itemBars.length, fixtureModel.items.length - 1);
  assert.ok(
    !itemBars.some((bar) => bar.customData.itemRef === 'dashboards'),
    'altitude-excluded item must have no bar',
  );
  assert.ok(
    !itemLabels.some((label) => label.customData.itemRef === 'dashboards'),
    'altitude-excluded item must have no label',
  );
});

test('an item whose bucketIds match no model bucket renders no bar and no label', () => {
  const model = {
    ...fixtureModel,
    items: fixtureModel.items.map((item) =>
      item.ref === 'ingest-api' ? { ...item, bucketIds: ['2099-Q1'] } : item,
    ),
  };

  const { elements } = renderLanes(model);
  const itemBars = byKind(elements, 'itemBar');
  const itemLabels = byKind(elements, 'itemLabel');

  assert.ok(!itemBars.some((bar) => bar.customData.itemRef === 'ingest-api'), 'unknown-bucket item must have no bar');
  assert.ok(!itemLabels.some((label) => label.customData.itemRef === 'ingest-api'), 'unknown-bucket item must have no label');
  assert.equal(itemBars.length, fixtureModel.items.length - 1, 'other items still render');
});

test('an item whose laneId matches no model lane renders no bar and no label', () => {
  const model = {
    ...fixtureModel,
    items: fixtureModel.items.map((item) =>
      item.ref === 'ingest-api' ? { ...item, laneId: 'no-such-lane' } : item,
    ),
  };

  const { elements } = renderLanes(model);
  const itemBars = byKind(elements, 'itemBar');
  const itemLabels = byKind(elements, 'itemLabel');

  assert.ok(!itemBars.some((bar) => bar.customData.itemRef === 'ingest-api'), 'unknown-lane item must have no bar');
  assert.ok(!itemLabels.some((label) => label.customData.itemRef === 'ingest-api'), 'unknown-lane item must have no label');
  assert.equal(itemBars.length, fixtureModel.items.length - 1, 'other items still render');
});

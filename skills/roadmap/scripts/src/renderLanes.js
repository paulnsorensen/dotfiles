
/**
 * Altitude-2 (workstream) view: renders a RoadmapModel (src/types.js) as a
 * swimlane diagram in Excalidraw element format.
 *
 * Layout is a fixed grid, not a proportional timeline:
 * - one horizontal lane band per model.lanes entry
 * - one vertical bucket-band column per model.buckets entry (band edges,
 *   not a continuous date axis)
 * - item bars snap to the bucket columns their bucketIds span; items
 *   sharing a lane are stacked into sub-rows so bars never overlap
 * - milestone verticals render only for milestones with a non-null date,
 *   positioned at the bucket their date falls into (derived in the model's
 *   bucket mode); a date outside every known bucket falls back to the
 *   item's start bucket, inside their item's sub-row
 *
 * Pure function: no I/O, no randomness. Element seed/versionNonce are
 * derived deterministically from the element id so repeat calls over the
 * same model produce identical output.
 */

import { filterByAltitude } from './altitudeFilter.js';
import { bucketIdForDate } from './mergeSidecar.js';

export const FRAME_NAME = 'Altitude 2 — Workstreams';

export const LANE_GEOMETRY = {
  laneHeaderWidth: 160,
  bucketWidth: 220,
  bucketHeaderHeight: 60,
  laneHeight: 160,
};

const LANE_TINTS = ['#e7f5ff', '#fff9db', '#f3f0ff', '#e6fcf5'];
const BUCKET_TINTS = ['#f8f9fa', '#ffffff'];
const ITEM_BAR_INSET_X = 12;
const ITEM_BAR_INSET_Y = 8;
const MILESTONE_WIDTH = 4;
const MILESTONE_INSET_Y = 4;
const FONT_FAMILY = 2; // Helvetica

function hashSeed(id) {
  let hash = 0;
  for (let index = 0; index < id.length; index += 1) {
    hash = (hash * 31 + id.charCodeAt(index)) | 0;
  }
  return Math.abs(hash) || 1;
}

function rectangle({ id, x, y, width, height, backgroundColor = 'transparent', strokeColor = '#1e1e1e', customData }) {
  const seed = hashSeed(id);
  return {
    id,
    type: 'rectangle',
    x,
    y,
    width,
    height,
    angle: 0,
    strokeColor,
    backgroundColor,
    fillStyle: 'solid',
    strokeWidth: 1,
    strokeStyle: 'solid',
    roughness: 0,
    opacity: 100,
    groupIds: [],
    frameId: null,
    roundness: null,
    seed,
    version: 1,
    versionNonce: seed,
    isDeleted: false,
    boundElements: null,
    updated: 0,
    link: null,
    locked: false,
    customData,
  };
}

function text({ id, x, y, width, height, text: value, fontSize = 16, strokeColor = '#1e1e1e', customData }) {
  const seed = hashSeed(id);
  return {
    id,
    type: 'text',
    x,
    y,
    width,
    height,
    angle: 0,
    strokeColor,
    backgroundColor: 'transparent',
    fillStyle: 'solid',
    strokeWidth: 1,
    strokeStyle: 'solid',
    roughness: 0,
    opacity: 100,
    groupIds: [],
    frameId: null,
    roundness: null,
    seed,
    version: 1,
    versionNonce: seed,
    isDeleted: false,
    boundElements: null,
    updated: 0,
    link: null,
    locked: false,
    text: value,
    fontSize,
    fontFamily: FONT_FAMILY,
    textAlign: 'left',
    verticalAlign: 'middle',
    baseline: fontSize,
    containerId: null,
    originalText: value,
    lineHeight: 1.25,
    customData,
  };
}

function bucketIndexById(buckets, bucketId) {
  return buckets.findIndex((bucket) => bucket.id === bucketId);
}


function itemBucketRange(item, buckets) {
  const indices = item.bucketIds
    .map((bucketId) => bucketIndexById(buckets, bucketId))
    .filter((index) => index !== -1);
  if (indices.length === 0) return null;
  return { start: Math.min(...indices), end: Math.max(...indices) };
}

function groupItemsByLane(items) {
  const itemsByLane = new Map();
  items.forEach((item) => {
    const laneItems = itemsByLane.get(item.laneId) ?? [];
    laneItems.push(item);
    itemsByLane.set(item.laneId, laneItems);
  });
  return itemsByLane;
}

/**
 * @param {import('./types.js').RoadmapModel} inputModel
 * @returns {{frameName: string, elements: object[]}}
 */
export function renderLanes(inputModel) {
  const model = filterByAltitude(inputModel, 2);
  const { buckets, lanes, items } = model;
  const { laneHeaderWidth, bucketWidth, bucketHeaderHeight, laneHeight } = LANE_GEOMETRY;

  const totalWidth = laneHeaderWidth + buckets.length * bucketWidth;
  const totalHeight = bucketHeaderHeight + lanes.length * laneHeight;

  const elements = [];

  buckets.forEach((bucket, bucketIndex) => {
    const x = laneHeaderWidth + bucketIndex * bucketWidth;
    elements.push(
      rectangle({
        id: `bucket-band-${bucket.id}`,
        x,
        y: 0,
        width: bucketWidth,
        height: totalHeight,
        backgroundColor: BUCKET_TINTS[bucketIndex % BUCKET_TINTS.length],
        strokeColor: '#ced4da',
        customData: { kind: 'bucketBand', bucketId: bucket.id },
      }),
    );
    elements.push(
      text({
        id: `bucket-label-${bucket.id}`,
        x: x + 12,
        y: (bucketHeaderHeight - 20) / 2,
        width: bucketWidth - 24,
        height: 20,
        text: bucket.label,
        fontSize: 16,
        customData: { kind: 'bucketLabel', bucketId: bucket.id },
      }),
    );
  });

  lanes.forEach((lane, laneIndex) => {
    const y = bucketHeaderHeight + laneIndex * laneHeight;
    elements.push(
      rectangle({
        id: `lane-band-${lane.id}`,
        x: 0,
        y,
        width: totalWidth,
        height: laneHeight,
        backgroundColor: LANE_TINTS[laneIndex % LANE_TINTS.length],
        strokeColor: '#adb5bd',
        customData: { kind: 'laneBand', laneId: lane.id },
      }),
    );
    elements.push(
      text({
        id: `lane-title-${lane.id}`,
        x: 12,
        y: y + laneHeight / 2 - 12,
        width: laneHeaderWidth - 24,
        height: 24,
        text: lane.title,
        fontSize: 18,
        customData: { kind: 'laneTitle', laneId: lane.id },
      }),
    );
  });

  const itemsByLane = groupItemsByLane(items);

  items.forEach((item) => {
    const laneIndex = lanes.findIndex((lane) => lane.id === item.laneId);
    const range = itemBucketRange(item, buckets);
    if (laneIndex === -1 || range === null) return;

    const laneItems = itemsByLane.get(item.laneId);
    const subRowIndex = laneItems.indexOf(item);
    const subRowHeight = laneHeight / laneItems.length;

    const laneY = bucketHeaderHeight + laneIndex * laneHeight;
    const subRowY = laneY + subRowIndex * subRowHeight;

    const barX = laneHeaderWidth + range.start * bucketWidth + ITEM_BAR_INSET_X;
    const barWidth = (range.end - range.start + 1) * bucketWidth - ITEM_BAR_INSET_X * 2;
    const barY = subRowY + ITEM_BAR_INSET_Y;
    const barHeight = subRowHeight - ITEM_BAR_INSET_Y * 2;

    elements.push(
      rectangle({
        id: `item-bar-${item.ref}`,
        x: barX,
        y: barY,
        width: barWidth,
        height: barHeight,
        backgroundColor: '#4dabf7',
        strokeColor: '#1864ab',
        customData: {
          kind: 'itemBar',
          itemRef: item.ref,
          laneId: item.laneId,
          bucketIds: item.bucketIds,
        },
      }),
    );
    elements.push(
      text({
        id: `item-label-${item.ref}`,
        x: barX + 8,
        y: barY + barHeight / 2 - 9,
        width: barWidth - 16,
        height: 18,
        text: item.title,
        fontSize: 14,
        strokeColor: '#0b2e4f',
        customData: { kind: 'itemLabel', itemRef: item.ref },
      }),
    );

    item.milestones
      .filter((milestone) => milestone.date)
      .forEach((milestone) => {
        const derivedBucketId = bucketIdForDate(milestone.date, model.bucketMode);
        const derivedIndex = bucketIndexById(buckets, derivedBucketId);
        const bucketIndex = derivedIndex !== -1 ? derivedIndex : range.start;
        const milestoneX = laneHeaderWidth + bucketIndex * bucketWidth + bucketWidth / 2;

        elements.push(
          rectangle({
            id: `milestone-line-${item.ref}-${milestone.id}`,
            x: milestoneX - MILESTONE_WIDTH / 2,
            y: subRowY + MILESTONE_INSET_Y,
            width: MILESTONE_WIDTH,
            height: subRowHeight - MILESTONE_INSET_Y * 2,
            backgroundColor: '#e03131',
            strokeColor: '#e03131',
            customData: {
              kind: 'milestone',
              itemRef: item.ref,
              milestoneId: milestone.id,
              bucketId: buckets[bucketIndex]?.id ?? null,
            },
          }),
        );
        elements.push(
          text({
            id: `milestone-label-${item.ref}-${milestone.id}`,
            x: milestoneX + 6,
            y: subRowY + MILESTONE_INSET_Y,
            width: bucketWidth / 2,
            height: 20,
            text: milestone.title,
            fontSize: 12,
            strokeColor: '#e03131',
            customData: {
              kind: 'milestoneLabel',
              itemRef: item.ref,
              milestoneId: milestone.id,
            },
          }),
        );
      });
  });

  return { frameName: FRAME_NAME, elements };
}

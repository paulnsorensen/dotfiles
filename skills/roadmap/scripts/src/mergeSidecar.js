
/**
 * mergeSidecar(linearModel, yamlText) -> RoadmapModel
 *
 * Parses the sidecar YAML, validates it against the SidecarConfig shape
 * (src/types.js), and merges it with the LinearModel fetched from Linear.
 * Conflict rule: Linear wins for every field Linear holds (title, status,
 * milestones, startDate/targetDate) - the sidecar schema simply has no keys
 * for those fields, so there is nothing to override. The sidecar only
 * contributes fields Linear has no concept of: unlocks, altitudes, lane
 * overrides, outcome cards, and fallback `blocks` edges.
 *
 * Validation fails loud: any unknown key or wrong-shaped value throws an
 * Error naming the offending field path (e.g. "items.ingest-api.altitude[0]")
 * before any part of the merge runs.
 *
 * Bucket derivation assumption (not specified by src/types.js): "cycles" mode
 * has no cycle metadata anywhere in LinearModel/SidecarConfig, so cycles are
 * modeled as fixed 14-day windows counted from a fixed epoch (2024-01-01),
 * ids "C<index>". "quarters" mode maps calendar quarters, ids "YYYY-Qn".
 */

import { parse as parseYaml } from 'yaml';

const TOP_LEVEL_KEYS = new Set(['subject', 'buckets', 'lanes', 'items', 'outcomes', 'notion']);
const LANE_KEYS = new Set(['id', 'title', 'initiative']);
const ITEM_KEYS = new Set(['unlocks', 'altitude', 'lane', 'blocks']);
const OUTCOME_KEYS = new Set(['title', 'horizon', 'items']);
const NOTION_KEYS = new Set(['page']);
const BUCKET_MODES = new Set(['quarters', 'cycles']);
const HORIZONS = new Set(['now', 'next', 'later']);
const ALTITUDES = new Set([1, 2, 3]);

const CYCLE_LENGTH_DAYS = 14;
const CYCLE_EPOCH_MS = Date.parse('2024-01-01T00:00:00Z');
const MS_PER_DAY = 24 * 60 * 60 * 1000;

function fail(path, message) {
  throw new Error(`sidecar config invalid at "${path}": ${message}`);
}

function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function assertString(value, path) {
  if (typeof value !== 'string') fail(path, `expected string, got ${typeof value}`);
}

function assertKeys(obj, allowed, path) {
  for (const key of Object.keys(obj)) {
    if (!allowed.has(key)) fail(`${path}.${key}`, 'unknown field');
  }
}

function validateLane(lane, path) {
  if (!isPlainObject(lane)) fail(path, 'expected object');
  assertKeys(lane, LANE_KEYS, path);
  if (!('id' in lane)) fail(`${path}.id`, 'missing required field');
  assertString(lane.id, `${path}.id`);
  if ('title' in lane) assertString(lane.title, `${path}.title`);
  if (!('initiative' in lane)) fail(`${path}.initiative`, 'missing required field');
  assertString(lane.initiative, `${path}.initiative`);
}

function validateItem(item, path) {
  if (!isPlainObject(item)) fail(path, 'expected object');
  assertKeys(item, ITEM_KEYS, path);
  if ('unlocks' in item) {
    if (!Array.isArray(item.unlocks)) fail(`${path}.unlocks`, 'expected array');
    item.unlocks.forEach((value, i) => assertString(value, `${path}.unlocks[${i}]`));
  }
  if ('altitude' in item) {
    if (!Array.isArray(item.altitude)) fail(`${path}.altitude`, 'expected array');
    item.altitude.forEach((value, i) => {
      if (!ALTITUDES.has(value)) fail(`${path}.altitude[${i}]`, 'expected one of 1, 2, 3');
    });
  }
  if ('lane' in item) assertString(item.lane, `${path}.lane`);
  if ('blocks' in item) {
    if (!Array.isArray(item.blocks)) fail(`${path}.blocks`, 'expected array');
    item.blocks.forEach((value, i) => assertString(value, `${path}.blocks[${i}]`));
  }
}

function validateOutcome(outcome, path) {
  if (!isPlainObject(outcome)) fail(path, 'expected object');
  assertKeys(outcome, OUTCOME_KEYS, path);
  if (!('title' in outcome)) fail(`${path}.title`, 'missing required field');
  assertString(outcome.title, `${path}.title`);
  if (!('horizon' in outcome)) fail(`${path}.horizon`, 'missing required field');
  if (!HORIZONS.has(outcome.horizon)) fail(`${path}.horizon`, 'expected one of now, next, later');
  if (!('items' in outcome)) fail(`${path}.items`, 'missing required field');
  if (!Array.isArray(outcome.items)) fail(`${path}.items`, 'expected array');
  outcome.items.forEach((value, i) => assertString(value, `${path}.items[${i}]`));
}

function validateSidecar(config) {
  if (!isPlainObject(config)) fail('$', 'expected object at root');
  assertKeys(config, TOP_LEVEL_KEYS, '$');

  if (!('subject' in config)) fail('subject', 'missing required field');
  assertString(config.subject, 'subject');

  if (!('buckets' in config)) fail('buckets', 'missing required field');
  if (!BUCKET_MODES.has(config.buckets)) fail('buckets', 'expected one of quarters, cycles');

  if ('lanes' in config) {
    if (!Array.isArray(config.lanes)) fail('lanes', 'expected array');
    config.lanes.forEach((lane, i) => validateLane(lane, `lanes[${i}]`));
  }

  if ('items' in config) {
    if (!isPlainObject(config.items)) fail('items', 'expected object');
    for (const [ref, item] of Object.entries(config.items)) {
      validateItem(item, `items.${ref}`);
    }
  }

  if ('outcomes' in config) {
    if (!Array.isArray(config.outcomes)) fail('outcomes', 'expected array');
    config.outcomes.forEach((outcome, i) => validateOutcome(outcome, `outcomes[${i}]`));
  }

  if ('notion' in config) {
    if (!isPlainObject(config.notion)) fail('notion', 'expected object');
    assertKeys(config.notion, NOTION_KEYS, 'notion');
    if (!('page' in config.notion)) fail('notion.page', 'missing required field');
    assertString(config.notion.page, 'notion.page');
  }
}

function quarterIndex(dateStr) {
  const [year, month] = dateStr.split('-').map(Number);
  return year * 4 + Math.floor((month - 1) / 3);
}

function quarterFromIndex(index) {
  const year = Math.floor(index / 4);
  const q = (index % 4) + 1;
  return { id: `${year}-Q${q}`, label: `Q${q} ${year}`, order: index };
}

function cycleIndex(dateStr) {
  const days = Math.floor((Date.parse(`${dateStr}T00:00:00Z`) - CYCLE_EPOCH_MS) / MS_PER_DAY);
  return Math.floor(days / CYCLE_LENGTH_DAYS);
}

function cycleFromIndex(index) {
  return { id: `C${index}`, label: `Cycle ${index}`, order: index };
}

function bucketsBetween(startDate, targetDate, mode) {
  const from = startDate ?? targetDate;
  const to = targetDate ?? startDate;
  if (from === null || from === undefined) return [];

  const [indexOf, fromIndex] = mode === 'cycles' ? [cycleFromIndex, cycleIndex] : [quarterFromIndex, quarterIndex];
  const start = fromIndex(from);
  const end = fromIndex(to);
  const buckets = [];
  for (let i = start; i <= end; i += 1) buckets.push(indexOf(i));
  return buckets;
}

/** Derives the bucket id an ISO date falls into, in the given bucket mode. */
export function bucketIdForDate(dateIso, mode) {
  return mode === 'cycles' ? cycleFromIndex(cycleIndex(dateIso)).id : quarterFromIndex(quarterIndex(dateIso)).id;
}

function laneMapFromSidecar(sidecarLanes) {
  const laneByInitiative = new Map();
  if (!sidecarLanes) return laneByInitiative;
  for (const lane of sidecarLanes) laneByInitiative.set(lane.initiative, lane.id);
  return laneByInitiative;
}

function dedupeEdges(edges) {
  const byKey = new Map();
  for (const edge of edges) {
    const key = `${edge.sourceRef}\u0000${edge.targetRef}`;
    const existing = byKey.get(key);
    if (!existing || (existing.source !== 'linear' && edge.source === 'linear')) {
      byKey.set(key, edge);
    }
  }
  return [...byKey.values()];
}

function sidecarBlockEdges(items) {
  const edges = [];
  for (const [ref, item] of Object.entries(items)) {
    for (const targetRef of item.blocks ?? []) {
      edges.push({ sourceRef: ref, targetRef, source: 'sidecar' });
    }
  }
  return edges;
}

export function mergeSidecar(linearModel, yamlText) {
  const parsed = parseYaml(yamlText) ?? {};
  validateSidecar(parsed);

  const sidecarItems = parsed.items ?? {};
  const mode = parsed.buckets;
  const laneByInitiative = laneMapFromSidecar(parsed.lanes);

  const bucketsById = new Map();
  const items = linearModel.projects.map((project) => {
    const sidecarItem = sidecarItems[project.ref];
    const laneId = sidecarItem?.lane ?? laneByInitiative.get(project.initiativeId) ?? project.initiativeId;
    const itemBuckets = bucketsBetween(project.startDate, project.targetDate, mode);
    for (const bucket of itemBuckets) {
      if (!bucketsById.has(bucket.id)) bucketsById.set(bucket.id, bucket);
    }

    return {
      ref: project.ref,
      title: project.title,
      laneId,
      bucketIds: itemBuckets.map((bucket) => bucket.id),
      status: project.status,
      milestones: project.milestones,
      unlocks: sidecarItem?.unlocks ?? [],
      altitudes: sidecarItem?.altitude ?? [1, 2, 3],
    };
  });

  const buckets = [...bucketsById.values()]
    .sort((a, b) => a.order - b.order)
    .map(({ id, label }) => ({ id, label }));

  const lanes = parsed.lanes
    ? parsed.lanes.map((lane) => ({ id: lane.id, title: lane.title ?? lane.id }))
    : linearModel.initiatives.map((initiative) => ({ id: initiative.id, title: initiative.title }));

  const edges = dedupeEdges([
    ...linearModel.relations.map((relation) => ({
      sourceRef: relation.sourceRef,
      targetRef: relation.targetRef,
      source: 'linear',
    })),
    ...sidecarBlockEdges(sidecarItems),
  ]);

  return {
    subject: parsed.subject,
    bucketMode: mode,
    buckets,
    lanes,
    items,
    edges,
    outcomes: parsed.outcomes ?? [],
    notion: parsed.notion ?? null,
  };
}

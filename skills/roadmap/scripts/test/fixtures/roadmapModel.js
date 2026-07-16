
/**
 * Shared fixture RoadmapModel used by renderer/filter/publish curd tests
 * in place of live Linear/Notion calls. Shape: src/types.js RoadmapModel.
 *
 * Deliberate properties exercised by tests:
 * - two lanes, three buckets (quarters)
 * - ingest-api blocks extraction-v2 via BOTH a linear edge and a duplicate
 *   sidecar edge (dedupe: linear must win)
 * - schema-registry -> dashboards edge exists only in sidecar (fallback kept)
 * - dashboards carries altitudes [1, 2] (excluded from the altitude-3 DAG)
 * - extraction-v2 has a milestone with a date; schema-registry one without
 */

/** @type {import('../../src/types.js').RoadmapModel} */
export const fixtureModel = {
  subject: 'KIP',
  bucketMode: 'quarters',
  buckets: [
    { id: '2026-Q3', label: 'Q3 2026' },
    { id: '2026-Q4', label: 'Q4 2026' },
    { id: '2027-Q1', label: 'Q1 2027' },
  ],
  lanes: [
    { id: 'ingest', title: 'Ingest' },
    { id: 'structured-data', title: 'Structured Data' },
  ],
  items: [
    {
      ref: 'ingest-api',
      title: 'Ingest API hardening',
      laneId: 'ingest',
      bucketIds: ['2026-Q3'],
      status: 'started',
      milestones: [],
      unlocks: ['Partners can push artifacts without manual review'],
      altitudes: [1, 2, 3],
    },
    {
      ref: 'extraction-v2',
      title: 'Extraction pipeline v2',
      laneId: 'ingest',
      bucketIds: ['2026-Q3', '2026-Q4'],
      status: 'planned',
      milestones: [{ id: 'm1', title: 'First extractor migrated', date: '2026-11-15' }],
      unlocks: ['Facts land within an hour of ingest'],
      altitudes: [1, 2, 3],
    },
    {
      ref: 'schema-registry',
      title: 'Schema registry',
      laneId: 'structured-data',
      bucketIds: ['2026-Q4'],
      status: 'planned',
      milestones: [{ id: 'm2', title: 'Registry API frozen', date: null }],
      unlocks: ['Teams declare structured data without KIP code changes'],
      altitudes: [1, 2, 3],
    },
    {
      ref: 'dashboards',
      title: 'Leadership dashboards',
      laneId: 'structured-data',
      bucketIds: ['2027-Q1'],
      status: 'planned',
      milestones: [],
      unlocks: ['Leadership reads roadmap state without asking'],
      altitudes: [1, 2],
    },
  ],
  edges: [
    { sourceRef: 'ingest-api', targetRef: 'extraction-v2', source: 'linear' },
    { sourceRef: 'schema-registry', targetRef: 'dashboards', source: 'sidecar' },
  ],
  outcomes: [
    { title: 'Ingest is self-serve', horizon: 'now', items: ['ingest-api', 'extraction-v2'] },
    { title: 'Structured data is declarative', horizon: 'next', items: ['schema-registry'] },
    { title: 'Roadmap reads itself', horizon: 'later', items: ['dashboards'] },
  ],
  notion: { page: 'fixture-page-id' },
};

/**
 * Raw pre-dedupe edge list (as mergeSidecar receives it): the linear edge and
 * its sidecar duplicate, plus the sidecar-only fallback edge. Curd tests that
 * exercise dedupe start from this.
 */
export const fixtureRawEdges = [
  { sourceRef: 'ingest-api', targetRef: 'extraction-v2', source: 'linear' },
  { sourceRef: 'ingest-api', targetRef: 'extraction-v2', source: 'sidecar' },
  { sourceRef: 'schema-registry', targetRef: 'dashboards', source: 'sidecar' },
];

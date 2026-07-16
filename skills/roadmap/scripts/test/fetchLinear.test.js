
import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';

import { fetchLinear } from '../src/fetchLinear.js';

const ORIGINAL_API_KEY = process.env.LINEAR_API_KEY;

beforeEach(() => {
  process.env.LINEAR_API_KEY = 'test-linear-key';
});

afterEach(() => {
  if (ORIGINAL_API_KEY === undefined) {
    delete process.env.LINEAR_API_KEY;
  } else {
    process.env.LINEAR_API_KEY = ORIGINAL_API_KEY;
  }
});

function jsonResponse(body, { ok = true, status = 200 } = {}) {
  return { ok, status, json: async () => body };
}

const sampleBody = {
  data: {
    projects: {
      nodes: [
        {
          id: 'proj-1',
          slugId: 'ingest-api',
          name: 'Ingest API hardening',
          status: { name: 'started' },
          startDate: '2026-07-01',
          targetDate: '2026-09-01',
          initiative: { id: 'init-1', name: 'Ingest' },
          projectMilestones: { nodes: [{ id: 'm1', name: 'Alpha', targetDate: '2026-08-01' }] },
          relations: { nodes: [{ type: 'blocks', relatedProject: { id: 'proj-2', slugId: 'extraction-v2' } }] },
          inverseRelations: { nodes: [] },
        },
        {
          id: 'proj-2',
          slugId: 'extraction-v2',
          name: 'Extraction pipeline v2',
          status: { name: 'planned' },
          startDate: null,
          targetDate: null,
          initiative: null,
          projectMilestones: { nodes: [] },
          relations: { nodes: [] },
          inverseRelations: { nodes: [{ type: 'blocks', relatedProject: { id: 'proj-1', slugId: 'ingest-api' } }] },
        },
        {
          id: 'proj-3',
          slugId: 'schema-registry',
          name: 'Schema registry',
          status: { name: 'planned' },
          startDate: '2026-10-01',
          targetDate: '2026-12-01',
          initiative: { id: 'init-2', name: 'Structured Data' },
          projectMilestones: { nodes: [{ id: 'm2', name: 'Registry API frozen', targetDate: null }] },
          relations: { nodes: [] },
          inverseRelations: { nodes: [] },
        },
      ],
    },
    issues: {
      nodes: [
        {
          id: 'issue-1',
          project: { id: 'proj-1', slugId: 'ingest-api' },
          relations: {
            nodes: [
              { type: 'blocks', relatedIssue: { id: 'issue-2', project: { id: 'proj-2', slugId: 'extraction-v2' } } },
            ],
          },
        },
        {
          id: 'issue-2',
          project: { id: 'proj-1', slugId: 'ingest-api' },
          relations: {
            nodes: [
              { type: 'blocks', relatedIssue: { id: 'issue-3', project: { id: 'proj-1', slugId: 'ingest-api' } } },
            ],
          },
        },
        {
          id: 'issue-3',
          project: { id: 'proj-3', slugId: 'schema-registry' },
          relations: {
            nodes: [
              {
                type: 'blocks',
                relatedIssue: { id: 'issue-4', project: { id: 'proj-999', slugId: 'unlisted-project' } },
              },
              {
                type: 'related',
                relatedIssue: { id: 'issue-5', project: { id: 'proj-2', slugId: 'extraction-v2' } },
              },
            ],
          },
        },
      ],
    },
  },
};

test('fetchLinear posts a single read-only GraphQL request to api.linear.app', async () => {
  const calls = [];
  const transport = async (url, init) => {
    calls.push({ url, init });
    return jsonResponse(sampleBody);
  };

  await fetchLinear('KIP', { transport });

  assert.equal(calls.length, 1);
  const [{ url, init }] = calls;
  assert.equal(url, 'https://api.linear.app/graphql');
  assert.equal(init.method, 'POST');
  assert.equal(init.headers.Authorization, 'test-linear-key');
  assert.equal(init.headers['Content-Type'], 'application/json');

  const payload = JSON.parse(init.body);
  assert.match(payload.query, /projects/);
  assert.match(payload.query, /issues/);
  assert.deepEqual(payload.variables, { teamKey: 'KIP' });
});

test('fetchLinear maps projects, milestones, and deduped initiatives', async () => {
  const transport = async () => jsonResponse(sampleBody);

  const model = await fetchLinear('KIP', { transport });

  assert.equal(model.team, 'KIP');
  assert.deepEqual(model.projects, [
    {
      ref: 'ingest-api',
      title: 'Ingest API hardening',
      initiativeId: 'init-1',
      status: 'started',
      startDate: '2026-07-01',
      targetDate: '2026-09-01',
      milestones: [{ id: 'm1', title: 'Alpha', date: '2026-08-01' }],
    },
    {
      ref: 'extraction-v2',
      title: 'Extraction pipeline v2',
      initiativeId: null,
      status: 'planned',
      startDate: null,
      targetDate: null,
      milestones: [],
    },
    {
      ref: 'schema-registry',
      title: 'Schema registry',
      initiativeId: 'init-2',
      status: 'planned',
      startDate: '2026-10-01',
      targetDate: '2026-12-01',
      milestones: [{ id: 'm2', title: 'Registry API frozen', date: null }],
    },
  ]);
  assert.deepEqual(model.initiatives, [
    { id: 'init-1', title: 'Ingest' },
    { id: 'init-2', title: 'Structured Data' },
  ]);
});

test('fetchLinear rolls up project + issue blocking relations to project refs, deduped', async () => {
  const transport = async () => jsonResponse(sampleBody);

  const model = await fetchLinear('KIP', { transport });

  // ingest-api -> extraction-v2 appears via project.relations, project.inverseRelations
  // (from extraction-v2's side), and an issue-level rollup — all collapse to one edge.
  // schema-registry -> unlisted-project comes only from an issue-level rollup against a
  // project outside the returned project list. The intra-project issue relation and the
  // non-"blocks" relation type are both excluded.
  assert.deepEqual(model.relations, [
    { sourceRef: 'ingest-api', targetRef: 'extraction-v2', type: 'blocks' },
    { sourceRef: 'schema-registry', targetRef: 'unlisted-project', type: 'blocks' },
  ]);
});

test('fetchLinear throws when LINEAR_API_KEY is not set', async () => {
  delete process.env.LINEAR_API_KEY;
  const transport = async () => jsonResponse(sampleBody);

  await assert.rejects(() => fetchLinear('KIP', { transport }), /LINEAR_API_KEY/);
});

test('fetchLinear throws when the HTTP response is not ok', async () => {
  const transport = async () => jsonResponse({}, { ok: false, status: 500 });

  await assert.rejects(() => fetchLinear('KIP', { transport }), /500/);
});

test('fetchLinear throws when the GraphQL response contains errors', async () => {
  const transport = async () => jsonResponse({ errors: [{ message: 'boom' }] });

  await assert.rejects(() => fetchLinear('KIP', { transport }), /boom/);
});

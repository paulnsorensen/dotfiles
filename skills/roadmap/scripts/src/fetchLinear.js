
/**
 * Read-only Linear GraphQL client for the /roadmap generator.
 * fetchLinear(team, {transport}) -> LinearModel (src/types.js).
 * transport is injected (fetch-like: (url, init) => Promise<{ok, status, json()}>)
 * so callers/tests can avoid live network access.
 */

const LINEAR_API_URL = 'https://api.linear.app/graphql';

const QUERY = `
  query RoadmapTeamData($teamKey: String!) {
    projects(filter: { team: { key: { eq: $teamKey } } }) {
      nodes {
        id
        slugId
        name
        status { name }
        startDate
        targetDate
        initiative { id name }
        projectMilestones { nodes { id name targetDate } }
        relations { nodes { type relatedProject { id slugId } } }
        inverseRelations { nodes { type relatedProject { id slugId } } }
      }
    }
    issues(filter: { team: { key: { eq: $teamKey } } }) {
      nodes {
        id
        project { id slugId }
        relations { nodes { type relatedIssue { id project { id slugId } } } }
      }
    }
  }
`;

function projectRef(project) {
  return project.slugId ?? project.id;
}

function addBlockingEdge(edges, seen, sourceRef, targetRef) {
  const key = `${sourceRef}->${targetRef}`;
  if (seen.has(key)) return;
  seen.add(key);
  edges.push({ sourceRef, targetRef, type: 'blocks' });
}

function toProject(project) {
  return {
    ref: projectRef(project),
    title: project.name,
    initiativeId: project.initiative?.id ?? null,
    status: project.status?.name ?? null,
    startDate: project.startDate ?? null,
    targetDate: project.targetDate ?? null,
    milestones: (project.projectMilestones?.nodes ?? []).map((milestone) => ({
      id: milestone.id,
      title: milestone.name,
      date: milestone.targetDate ?? null,
    })),
  };
}

function collectInitiatives(projectNodes) {
  const byId = new Map();
  for (const project of projectNodes) {
    if (project.initiative && !byId.has(project.initiative.id)) {
      byId.set(project.initiative.id, { id: project.initiative.id, title: project.initiative.name });
    }
  }
  return [...byId.values()];
}

function collectProjectRelations(projectNodes, edges, seen) {
  for (const project of projectNodes) {
    const sourceRef = projectRef(project);
    for (const relation of project.relations?.nodes ?? []) {
      if (relation.type !== 'blocks' || !relation.relatedProject) continue;
      addBlockingEdge(edges, seen, sourceRef, projectRef(relation.relatedProject));
    }
    for (const relation of project.inverseRelations?.nodes ?? []) {
      if (relation.type !== 'blocks' || !relation.relatedProject) continue;
      addBlockingEdge(edges, seen, projectRef(relation.relatedProject), sourceRef);
    }
  }
}

function collectIssueRelations(issueNodes, edges, seen) {
  for (const issue of issueNodes) {
    const sourceProject = issue.project;
    if (!sourceProject) continue;
    for (const relation of issue.relations?.nodes ?? []) {
      if (relation.type !== 'blocks') continue;
      const targetProject = relation.relatedIssue?.project;
      if (!targetProject || targetProject.id === sourceProject.id) continue;
      addBlockingEdge(edges, seen, projectRef(sourceProject), projectRef(targetProject));
    }
  }
}

/**
 * @param {string} team  Linear team key (e.g. "KIP")
 * @param {{transport?: (url: string, init: object) => Promise<{ok: boolean, status: number, json: () => Promise<object>}>}} [options]
 * @returns {Promise<import('./types.js').LinearModel>}
 */
export async function fetchLinear(team, { transport = fetch } = {}) {
  const apiKey = process.env.LINEAR_API_KEY;
  if (!apiKey) {
    throw new Error('LINEAR_API_KEY environment variable is not set');
  }

  const response = await transport(LINEAR_API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: apiKey,
    },
    body: JSON.stringify({ query: QUERY, variables: { teamKey: team } }),
  });

  if (!response.ok) {
    throw new Error(`Linear API request failed with status ${response.status}`);
  }

  const body = await response.json();
  if (body.errors?.length) {
    throw new Error(`Linear API returned errors: ${body.errors.map((error) => error.message).join('; ')}`);
  }

  const projectNodes = body.data?.projects?.nodes ?? [];
  const issueNodes = body.data?.issues?.nodes ?? [];

  const relations = [];
  const seen = new Set();
  collectProjectRelations(projectNodes, relations, seen);
  collectIssueRelations(issueNodes, relations, seen);

  return {
    team,
    projects: projectNodes.map(toProject),
    initiatives: collectInitiatives(projectNodes),
    relations,
  };
}

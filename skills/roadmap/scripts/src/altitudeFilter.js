
/**
 * Restricts a RoadmapModel (see src/types.js) to items visible at a given
 * altitude, dropping edges and outcome members that reference excluded items.
 * Pure: does not mutate the input model.
 */

/**
 * @param {import('./types.js').RoadmapModel} model
 * @param {1|2|3} altitude
 * @returns {import('./types.js').RoadmapModel}
 */
function filterByAltitude(model, altitude) {
  const keptRefs = new Set(
    model.items
      .filter((item) => !item.altitudes || item.altitudes.includes(altitude))
      .map((item) => item.ref),
  );

  const items = model.items.filter((item) => keptRefs.has(item.ref));

  const edges = model.edges.filter(
    (edge) => keptRefs.has(edge.sourceRef) && keptRefs.has(edge.targetRef),
  );

  const outcomes = model.outcomes
    .map((outcome) => ({ ...outcome, items: outcome.items.filter((ref) => keptRefs.has(ref)) }))
    .filter((outcome) => outcome.items.length > 0);

  return { ...model, items, edges, outcomes };
}

export { filterByAltitude };


/**
 * Shared type shapes for the /roadmap generator.
 * Data flow: fetchLinear() -> LinearModel; mergeSidecar(LinearModel, SidecarConfig) -> RoadmapModel.
 * Conflict rule: Linear wins for fields Linear holds; sidecar wins for its own fields
 * (unlocks, altitudes, lane overrides, outcome cards, fallback blocks).
 */

/**
 * @typedef {Object} LinearRelation
 * @property {string} sourceRef  Linear project (or issue) ref the relation starts from
 * @property {string} targetRef  ref the source blocks
 * @property {'blocks'} type     only blocking edges are modeled
 */

/**
 * @typedef {Object} LinearMilestone
 * @property {string} id
 * @property {string} title
 * @property {string|null} date  ISO date, null when unset
 */

/**
 * @typedef {Object} LinearProject
 * @property {string} ref        stable ref used as item key (project slug or id)
 * @property {string} title
 * @property {string|null} initiativeId
 * @property {string|null} status
 * @property {string|null} startDate   ISO date
 * @property {string|null} targetDate  ISO date
 * @property {LinearMilestone[]} milestones
 */

/**
 * @typedef {Object} LinearInitiative
 * @property {string} id
 * @property {string} title
 */

/**
 * @typedef {Object} LinearModel
 * @property {string} team
 * @property {LinearProject[]} projects
 * @property {LinearInitiative[]} initiatives
 * @property {LinearRelation[]} relations  from Project.relations/inverseRelations (+ issue-level rollup)
 */

/**
 * @typedef {Object} SidecarItem
 * @property {string[]} [unlocks]    user-value statements, rendered at altitude 1
 * @property {(1|2|3)[]} [altitude]  views that include this item; default all
 * @property {string} [lane]         lane-id override
 * @property {string[]} [blocks]     fallback dependency targets; used only when Linear lacks the edge
 */

/**
 * @typedef {Object} SidecarOutcome
 * @property {string} title
 * @property {'now'|'next'|'later'} horizon
 * @property {string[]} items  project refs
 */

/**
 * @typedef {Object} SidecarConfig
 * @property {string} subject
 * @property {'quarters'|'cycles'} buckets
 * @property {{id: string, title?: string, initiative: string}[]} [lanes]
 * @property {Object<string, SidecarItem>} [items]  keyed by project ref
 * @property {SidecarOutcome[]} [outcomes]
 * @property {{page: string}} [notion]
 */

/**
 * @typedef {Object} RoadmapEdge
 * @property {string} sourceRef
 * @property {string} targetRef
 * @property {'linear'|'sidecar'} source  provenance; linear preferred on duplicate
 */

/**
 * @typedef {Object} RoadmapItem
 * @property {string} ref
 * @property {string} title
 * @property {string} laneId
 * @property {string[]} bucketIds   coarse bands the item spans (quarter/cycle ids)
 * @property {string|null} status
 * @property {LinearMilestone[]} milestones
 * @property {string[]} unlocks
 * @property {(1|2|3)[]} altitudes  views that include this item
 */

/**
 * @typedef {Object} RoadmapLane
 * @property {string} id
 * @property {string} title
 */

/**
 * @typedef {Object} RoadmapBucket
 * @property {string} id     e.g. "2026-Q3"
 * @property {string} label  e.g. "Q3 2026"
 */

/**
 * @typedef {Object} RoadmapModel
 * @property {string} subject
 * @property {'quarters'|'cycles'} bucketMode  active bucket derivation mode
 * @property {RoadmapBucket[]} buckets   ordered coarse time bands
 * @property {RoadmapLane[]} lanes
 * @property {RoadmapItem[]} items
 * @property {RoadmapEdge[]} edges       deduped union of Linear relations and sidecar blocks
 * @property {SidecarOutcome[]} outcomes
 * @property {{page: string}|null} notion
 */

export {};

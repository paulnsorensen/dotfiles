// module: mold; provides: MOLD, DECISION_KINDS, RESEARCH_CONFIDENCE; requires: none
// mold resolves the spec, research, and notes artifact paths.
const MOLD = 'python3 ~/.claude/skills/mold/scripts/mold.pyz'
// A Ground explorer sorts each recorded wiki decision into one of these kinds.
const DECISION_KINDS = ['adr', 'locked', 'roadmap', 'gotcha', 'strategy']
// brie-ground returns one of these confidence values.
const RESEARCH_CONFIDENCE = ['certain', 'speculating', 'dont_know']

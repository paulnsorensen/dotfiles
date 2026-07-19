export const meta = {
  name: 'deep-research',
  description: 'Deep, multi-source, fact-checked research — runs the combined brie-ground engine (dynamic wiki + Tavily fan-out, prior-research reuse, adversarial verify, cited synthesis).',
  whenToUse: 'When the user wants a deep, multi-source, fact-checked research report on any topic. BEFORE invoking, check if the question is specific enough to research directly — if underspecified (e.g., "what car to buy" without budget/use-case/region), ask 2-3 clarifying questions to narrow scope. Then pass the refined question as args, weaving the answers in.',
  phases: [{ title: 'Delegate', detail: 'run the brie-ground engine on the question' }],
}

// DISABLES the bundled deep-research workflow by shadowing it. Claude Code
// filters out any built-in workflow whose name a user (or plugin) workflow
// already defines — the merger does `v7r().filter(a => !userNames.has(a.name))`.
// Deploying this file as ~/.claude/workflows/deep-research.js (claude asset →
// chezmoi exact_workflows) claims the `deep-research` name, so the compiled-in
// version is dropped and /deep-research runs the combined engine below instead.
//
// One implementation: the bundled pipeline's capability (multi-angle fan-out,
// fetch, adversarial verify, synthesis) now lives in brie-ground as a dynamic
// per-sub-question "deep" escalation, hard-coded to Tavily and far more token-
// efficient than the fixed ~97-agent bundled run. This shim just forwards.

return await workflow('brie-ground', args)

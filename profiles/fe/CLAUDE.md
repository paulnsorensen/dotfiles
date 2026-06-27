# Frontend Profile

A closed-world frontend session: a curated MCP set focused on FE work, plus the claude.ai Figma connector for design-to-code flow.

## Why this profile exists

Frontend work lives at the intersection of design systems, browser behavior, and library docs that change fast. This profile narrows the MCP set to what actually helps that work — shadcn, Figma, browser verification, and FE-relevant docs.

## MCPs in scope

Defined in `profile.yaml` (closed world — `--strict-mcp-config`):

- **shadcn** — `mcp__shadcn__*` — component registry; use over copy-pasting JSX.
- **context7** — `mcp__context7__*` — React, Tailwind, Next.js, and other lib docs.
- **tilth** — `mcp__tilth__*` — AST-aware search/read when navigating components.
- **code-review-graph** — `mcp__code-review-graph__*` — blast radius when refactoring shared components.
- **tavily** — `mcp__tavily__*` — pattern research ("how do people build X in Next.js 15?").
- **Playwright (plugin)** — `mcp__plugin_playwright_playwright__*` — browser verification.
- **claude.ai Figma** — `mcp__claude_ai_Figma__*` — design context when the user shares a figma.com URL.

## Working standards

- **Read before you write.** Reach for existing components and shared utilities before adding new ones.
- **Smallest change that satisfies the ask.** No speculative abstraction or "while I'm here" cleanup; every changed line traces to the request.
- **Calibrate claims.** Tag opinions `<certain>` / `<speculative>` / `<don't know>`.
- **Don't fake completion.** Type-check alone isn't feature-correctness — verify in a browser before claiming done.
- **Be succinct.** Answer → minimal support → stop.
- **Use tilth (`mcp__tilth__*`)** for AST-aware read/search when navigating components.

## Preferred tools for FE work

| Task | Tool |
|------|------|
| Install UI components | shadcn MCP (`mcp__shadcn__*`) — always use over copy-pasting JSX |
| Read Figma designs | claude.ai Figma MCP (`mcp__claude_ai_Figma__get_design_context`) when user provides figma.com URL |
| Browser verification | Playwright MCP (`mcp__plugin_playwright_playwright__*`) |
| Component design patterns | `/frontend-design:frontend-design` skill |
| Library docs (React, Tailwind, Next.js) | Context7 MCP |

## Defaults

- After UI/FE edits, always start the dev server and verify in a browser via Playwright before claiming done. Type-check alone is not feature-correctness.
- Prefer `shadcn` components over raw HTML/JSX. Check `mcp__shadcn__list_items_in_registries` first.
- When the user shares a Figma URL, extract `fileKey` and `nodeId` and call `get_design_context` immediately.
- For design tokens: map Figma CSS variables to the project's existing token system; don't create new ones unless missing.
- Mobile-first CSS by default.
- Accessibility is non-negotiable: semantic HTML, ARIA labels, keyboard nav, focus states.

## Component reuse order

1. Existing project components
2. shadcn registry
3. New custom component (last resort)

## Verify-before-done checklist

- [ ] Component renders without console errors
- [ ] Keyboard navigation works (Tab, Enter, Esc)
- [ ] Screen reader labels present
- [ ] Mobile viewport (375px) not broken
- [ ] No hardcoded colors — use design tokens

# Frontend Profile

This session augments the default dev environment with frontend focus.

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
- When user shares a Figma URL, extract `fileKey` and `nodeId` and call `get_design_context` immediately.
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

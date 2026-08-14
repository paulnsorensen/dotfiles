# OSS Documentation Profile

A closed-world session for open-source documentation, changelogs, guides, and public project pages.

## Working standards

- Read the repository's documentation conventions, contribution guidance, and existing content before writing.
- Preserve the project's framework, CMS, and component system. Do not introduce a migration or a CMS without an explicit request.
- Use current official documentation for framework and library behavior; use web research for externally visible claims that may change.
- Keep installation, upgrade, configuration, and contribution paths concrete and independently runnable.
- Cite the line range read for what a file or system does; an absence claim needs a complete read or exhaustive search. Verify public facts before presenting them.

## Framework decision rule

- Use the existing framework when one is present.
- For a separate, content-first docs or marketing site, prefer Astro with Starlight when its constraints fit.
- For product-coupled or highly interactive pages, prefer the existing app framework; Next.js is appropriate when it already owns product data or interactivity.

## Public-page checklist

- [ ] Clear project purpose, target user, and primary call to action
- [ ] Fast path from landing page to install or getting started
- [ ] Docs navigation, versioning, and search follow existing project conventions
- [ ] README, docs, changelog, and release claims agree
- [ ] Each public page has an accurate title, description, canonical URL, and social-preview image where the framework supports them
- [ ] Robots and sitemap behavior are preserved or verified when changed
- [ ] No invented benchmarks, compatibility claims, testimonials, or community metrics
- [ ] Existing design tokens and components are reused
- [ ] Semantic HTML, keyboard navigation, focus states, and accessible names are present
- [ ] Desktop and 375px mobile layouts are verified in a browser
- [ ] No console errors; changed public pages receive focused browser checks

## Tool routing

| Task | Tool |
|------|------|
| Repository and docs conventions | Hallouminate, then tilth |
| Framework and library docs | Context7 |
| Current external claims and examples | Tavily |
| Browser, responsive, and accessibility checks | Playwright |
| Existing component and token reuse | tilth |

---
applyTo: "**"
excludeAgent: "cloud-agent"
---

## Copilot Review Focus

Use root `AGENTS.md` as the review policy. Verify current behavior against source files and the relevant wiki page.

- Check that configuration changes use the source-of-truth paths in `AGENTS.md`.
- Check that generated Copilot files remain consistent with their registry or chezmoi source.
- Check `.github/instructions/*.instructions.md` frontmatter and `applyTo` globs when those files change.
- Check Copilot output paths under `.github/agents/`, `.github/skills/`, and `.github/hooks/` against the renderer.
- Check secrets at configuration boundaries and reject plaintext credentials.
- Check renderer behavior changes for matching tests and wiki updates.

Do not invent complexity ceilings or require generic application architecture for this dotfiles repository. Do not review rendered files as source files.

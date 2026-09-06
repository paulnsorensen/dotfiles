---
applyTo: "bin/**,**/*.sh,**/*.sh.tmpl,**/*.zsh,**/*.bash,.sync,**/.sync,**/*.bats,.vars,iterm2/.scrub,iterm2/.updatetemplate"
---

## Shell Files

Use root `AGENTS.md` for shell policy and test requirements.

- Treat `.zsh` files under `zsh/` as sourced libraries, not executable scripts.
- Add shebangs and strict mode only to executable scripts that own process boundaries.
- Quote variable expansions and preserve the file's existing shell dialect.
- Keep Copilot hook scripts under their declared source path; generated `.github/hooks/` files are output.
- Keep secrets out of shell files and templates.

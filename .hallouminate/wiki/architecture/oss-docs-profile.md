# OSS docs profile

`oss-docs` is an isolated `ap` profile for open-source documentation, changelogs, guides, and public project pages. It keeps framework and CMS choices in the target project while supplying code navigation, repository grounding, current documentation and web research, plus browser verification.[^1]

Its system prompt requires a concrete install path, agreement among README/docs/changelog/release claims, metadata and social-preview review where supported, no invented public claims, reuse of existing components, and browser/a11y checks at desktop and 375px.[^2]

Use `cdp oss-docs` to launch the profile in Codex; `cdp list` lists available profiles. The shortcut forwards directly to `dots profile launch codex` and therefore retains isolated-launch behavior.[^3]

[^1]: profiles/oss-docs/profile.yaml:1-34
[^2]: profiles/oss-docs/CLAUDE.md:5-41
[^3]: zsh/claude.zsh:123-137

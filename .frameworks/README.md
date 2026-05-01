# Framework comparison foundations

These foundations let the repository evaluate established dotfile managers without deleting the current `dots sync` path.

| Framework | Foundation path | Best fit | Why it is here |
| --- | --- | --- | --- |
| Chezmoi | `.frameworks/chezmoi/` | Long-term default candidate | Strong templating, multi-machine support, and built-in dry-run tooling |
| Dotbot | `.frameworks/dotbot/` | Lowest migration risk | Mirrors the current symlink + shell-script orchestration closely |
| dotdrop | `.frameworks/dotdrop/` | Profile-heavy setups | Profiles and actions map well to macOS/Linux/dev install splits |

## Recommendation

- Choose **Chezmoi** if long-term maintainability, templating, and multi-machine support matter most.
- Choose **Dotbot** if minimal migration and keeping the current repository layout matter most.
- Choose **dotdrop** if host/profile-specific actions become the primary organizing principle.
- Keep **`dots sync`** as the production fallback until one framework has proven itself on real machines.

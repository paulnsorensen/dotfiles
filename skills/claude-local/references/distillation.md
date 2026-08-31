# Distillation rules — what stays, what goes

These aren't a checklist to copy verbatim; they're the judgment to bring.

## Project-context signals

Glob from the repo root:

| Signal | Implies |
|--------|---------|
| `Cargo.toml` | Rust |
| `package.json` (+ `tsconfig.json`) | TypeScript |
| `package.json` (no tsconfig) | JavaScript |
| `pyproject.toml` / `setup.py` / `requirements.txt` | Python |
| `go.mod` | Go |
| `Gemfile` | Ruby |
| `pom.xml` / `build.gradle*` | Java / Kotlin |
| `composer.json` | PHP |
| `mix.exs` | Elixir |
| `*.csproj` / `*.sln` | C# / .NET |

A project can be multi-language. Capture every language signal you find.
Note the build/runtime tooling you observe (uv vs pip, pnpm vs npm vs yarn,
cargo vs bazel) so the output references what the project actually uses.

## Always keep

- **Coding principles.** Input validation, fail-fast, loose coupling,
  YAGNI, real-world models, immutable patterns. These are language- and
  project-agnostic and travel everywhere.
- **Operational rules.** Skill-over-bash delegation (`cheez-search` over
  `grep`, `cheez-read` over `cat`, `cheez-write` over `sed`, `jq`/`yq`
  over inline `python3 -c`, `gh` over raw GitHub API), CLI tools
  (jq/yq/tokei/duckdb), agent permission model (bypassPermissions ≠ Bash
  bypass), agent nesting limits. These apply in any repo.
- **Build system rules.** "Fix the version, don't restructure the build"
  — this is hard-won and applies to any project's deps.

## Language-gate (include only if the project uses the language)

- **Python preference (`uv`)** — only include if you saw a `pyproject.toml`,
  `setup.py`, or `requirements.txt`.
- **Code style entries** — keep only the conventions for languages
  actually present. A pure-Rust project doesn't need the JS/TS camelCase
  rule.

## Drop entirely (personal, not project-relevant)

- **Communication style** — the cheese / Dune / Mad Max flair. This is a
  personal-conversation preference. Even though `CLAUDE.local.md` is
  gitignored, a stray `git add -f` or grep across `$HOME` could surface it
  in a contributed repo's history. Keep the flair scoped to the global file.
- **Sliced Bread architecture** — the user's preferred file layout. In a
  contributed repo, the project's own structure is authoritative; the
  user shouldn't push a personal architecture on a codebase they don't
  own.
- **Early Development Stance** — "no backward compatibility concerns" only
  applies to the user's own unreleased projects. A contributed repo
  almost certainly has users.
- **Workflow / Cheddar Flow** beyond a brief reference. The full skill
  catalog is in the global file; the local overlay just needs to remind
  Claude that `/age`, `/cure`, `/respond`, and `/de-slop` exist and are
  preferred. For autonomous flows on large changes, `/cook` chains
  cook → press → age → cure.
- **Troubleshooting one-liners** (`/go`, `/lsp`) — meta-tool
  state, irrelevant to any project.
- **RTK** — the rtk proxy is a personal tooling layer; it's auto-applied
  by hooks regardless and doesn't need to be repeated in a project file.

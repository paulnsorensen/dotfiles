# Phase 0 Detail: Manifests, depManifest, Dependency Health

## 0.1 Find Manifest Files

```
Glob: **/package.json
Glob: **/Cargo.toml
Glob: **/pyproject.toml
Glob: **/go.mod
Glob: **/Gemfile
Glob: **/requirements.txt
Glob: **/composer.json
Glob: **/build.gradle
Glob: **/pom.xml
Glob: **/mix.exs
```

Filter out manifests inside node_modules/, vendor/, .git/, build/.

## 0.2 Extract Dependencies

For each manifest, extract dependency names into a flat set:

| Manifest | Extract command |
|----------|----------------|
| package.json | `jq -r '(.dependencies + .devDependencies) // {} \| keys[]'` |
| Cargo.toml | `yq -r '.dependencies \| keys[]'` or parse `[dependencies]` section |
| pyproject.toml | `yq -r '.project.dependencies[]'` or `[tool.poetry.dependencies]` |
| go.mod | `grep '^require' + parse module paths` |
| requirements.txt | line-by-line package names |

Store as `depManifest`:

```json
{
  "workspaces": {
    ".": { "ecosystem": "node", "deps": ["express", "zod", "uuid"] }
  },
  "primaryLanguages": ["typescript"]
}
```

## 0.3 Detect Primary Languages

Infer from manifest types + file extensions in scope. This determines which
ast-grep patterns the scanner will run.

## 0.4 Dependency Health

Same manifests, three cheap checks — a dependency you can delete beats one you
replace.

Run whichever audit tool the ecosystem already has. Never install one:

| Ecosystem | Command |
|---|---|
| Node | `npm audit --json 2>/dev/null \| head -50` |
| Python | `uv pip audit 2>/dev/null \|\| pip-audit 2>/dev/null` |
| Rust | `cargo audit 2>/dev/null` |
| Go | `govulncheck ./... 2>/dev/null` |

If the tool is absent, report it as skipped — an unrun audit is not a clean one.

Then, per dependency in `depManifest`:

- **Possibly unused** — zero import matches in source. Plugins, runtime-only
  deps, and CLI tools are used implicitly: mark those `<speculative>` and
  downgrade rather than recommending removal.
- **Overweight** — a heavyweight package pulled in for a single function.
- **Stdlib-replaceable** — `lodash` → native methods, `axios` → `fetch`,
  `uuid` → `crypto.randomUUID()`.

These are dependency findings, not NIH candidates: they need no library research,
so they skip Phases 2–3 and go straight to the Dependency Health block of the
report (see `report-format.md`).

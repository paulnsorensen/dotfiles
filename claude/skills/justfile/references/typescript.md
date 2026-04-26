# TypeScript/JavaScript Justfile Recipes

Detect the package manager from lockfiles:

- `bun.lockb` / `bun.lock` -> bun
- `pnpm-lock.yaml` -> pnpm
- `yarn.lock` -> yarn
- `package-lock.json` -> npm

## Template (npm — adapt runner for other managers)

```just
set dotenv-load := true

default: check

# Run all checks
check: lint typecheck test

# Install dependencies
install:
    npm install

# Run dev server
dev:
    npm run dev

# Build for production
build:
    npm run build

# Run tests
test *args:
    npm test -- {{args}}

# Lint (static analysis only — not typechecking)
lint:
    npx eslint src/

# Format
fmt:
    npx prettier --write .

# Type check only
typecheck:
    npx tsc --noEmit

# Full CI pipeline — hard-gate the coverage step
# (see references/rtk.md for the rtk test/err pattern)
build-ci:
    npm install
    just fmt
    just lint
    just typecheck
    just build
    rtk test npm run test:coverage

# Clean
clean:
    rm -rf dist/ node_modules/.cache
```

**Keep `lint` and `typecheck` as separate recipes and separate npm scripts.**
Conflating them (e.g. `"lint": "tsc --noEmit"`) breaks rtk's `npm run <script>`
wrapper, which infers tool output format from the script name. More importantly,
the name is a lie — ESLint/biome lints, tsc typechecks. Name the script after
what it runs.

## Bun variant

```just
install:
    bun install

dev:
    bun run dev

test *args:
    bun test {{args}}

build:
    bun run build
```

## Monorepo (Turborepo/Nx)

```just
# Build all packages
build-all:
    npx turbo build

# Test all packages
test-all:
    npx turbo test

# Run a specific workspace
dev workspace:
    npx turbo dev --filter={{workspace}}
```

## Notes

- Check `package.json` scripts — mirror the important ones as just recipes
- Don't duplicate every npm script — just wrap the most common workflows
- For Next.js/Vite/Remix, the `dev`/`build` recipes map to framework CLI
- If using Biome instead of ESLint+Prettier, use `npx biome check`/`npx biome format`

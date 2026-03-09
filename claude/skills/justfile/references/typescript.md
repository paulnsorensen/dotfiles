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

# Lint
lint:
    npx eslint src/
    npx tsc --noEmit

# Format
fmt:
    npx prettier --write .

# Type check only
typecheck:
    npx tsc --noEmit

# Clean
clean:
    rm -rf dist/ node_modules/.cache
```

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

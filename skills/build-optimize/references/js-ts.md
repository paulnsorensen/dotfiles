# JavaScript and TypeScript local build, test, and check options

## Turborepo and Nx caching

Declare Turborepo `outputs` when a task must restore files. A task without outputs can still cache logs and skip execution, but it cannot restore omitted file outputs. Declare every environment variable and input that affects task results. [Turborepo configuration](https://github.com/vercel/turborepo/blob/main/apps/docs/content/docs/reference/configuration.mdx)

Treat cache hits as valid only when task inputs and environment are complete. Review the project configuration before changing cache inputs.

Nx cache location is configurable. Use the project's `cacheDirectory` setting instead of assuming a fixed path. [Nx nx.json](https://nx.dev/docs/reference/nx-json)

## esbuild, SWC, and TypeScript

Esbuild and SWC transpile TypeScript. They do not type-check it. Keep the project's native `tsc` command for type-check coverage. [esbuild TypeScript](https://esbuild.github.io/content-types/#typescript) [SWC TypeScript](https://swc.rs/docs/usage/cli)

Do not impose a universal `tsc --build --noEmit` command. TypeScript project references can require declaration output. Use the command defined by the project. [TypeScript project references](https://www.typescriptlang.org/docs/handbook/project-references)

Use `tsc --incremental` only when the project supports its `.tsbuildinfo` state. Measure repeated comparable runs before claiming a gain. [TypeScript incremental](https://www.typescriptlang.org/tsconfig/incremental.html)

## Vitest

Use `maxWorkers` to limit workers. Use `fileParallelism: false` to disable file-level parallelism. Give tests unique files, ports, databases, and other external resources before increasing concurrency. [Vitest parallelism](https://vitest.dev/guide/parallelism.html)

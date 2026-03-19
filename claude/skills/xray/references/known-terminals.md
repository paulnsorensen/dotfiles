# Known Terminal Nodes

Well-known libraries that are terminal nodes in xray graphs. Terminal nodes are
auto-skipped during DFS verification — they are external dependencies that don't
need design review.

The scout marks any external dependency matching these entries as
`role: "terminal"`.

## Matching Rules

- **Exact match** by default: the import specifier's package name must equal an
  entry (e.g. `express` matches `import express from "express"`)
- **Prefix match** for entries ending with `*` (e.g. `google-cloud-*` matches
  `google-cloud-storage`, `google-cloud-pubsub`)
- **Slash-scoped**: entries with `/` match the full import path prefix
  (e.g. `gorilla/mux` matches `github.com/gorilla/mux`)
- Standard library modules are matched by language convention (no `node_modules`
  path for Node builtins, `std::` prefix for Rust, etc.)

## Universal

- Standard library modules (any language's stdlib)

## Node.js / TypeScript

- express
- fastify
- koa
- hapi
- nestjs
- next
- nuxt
- remix
- lodash
- underscore
- ramda
- winston
- pino
- bunyan
- pg
- mysql2
- better-sqlite3
- prisma
- drizzle
- knex
- typeorm
- sequelize
- axios
- got
- node-fetch
- undici
- zod
- joi
- yup
- ajv
- io-ts
- jest
- vitest
- mocha
- chai
- sinon
- supertest
- react
- vue
- svelte
- angular
- solid-js
- preact
- webpack
- vite
- esbuild
- rollup
- parcel
- turbopack
- tailwindcss
- postcss
- sass
- commander
- yargs
- inquirer
- chalk
- ora

## Python

- flask
- django
- fastapi
- starlette
- tornado
- aiohttp
- requests
- httpx
- urllib3
- sqlalchemy
- peewee
- tortoise-orm
- alembic
- pytest
- unittest
- nose2
- hypothesis
- pydantic
- attrs
- dataclasses-json
- marshmallow
- celery
- dramatiq
- rq
- huey
- numpy
- pandas
- scipy
- sklearn
- matplotlib
- seaborn
- click
- typer
- argparse
- rich
- boto3
- google-cloud-*
- azure-*

## Rust

- tokio
- async-std
- smol
- serde
- serde_json
- serde_yaml
- bincode
- postcard
- reqwest
- hyper
- axum
- actix-web
- warp
- rocket
- tonic
- sqlx
- diesel
- sea-orm
- rusqlite
- clap
- structopt
- tracing
- log
- env_logger
- anyhow
- thiserror
- eyre
- color-eyre
- rayon
- crossbeam
- parking_lot
- rand
- uuid
- chrono
- time
- regex

## Go

- net/http
- gin
- echo
- fiber
- chi
- gorilla/mux
- database/sql
- gorm
- sqlx
- pgx
- ent
- zap
- zerolog
- logrus
- slog
- cobra
- urfave/cli
- pflag
- testify
- gomock
- httptest
- context
- sync
- encoding/json
- fmt
- os
- io
- strings
- strconv
- errors

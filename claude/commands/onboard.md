---
name: onboard
description: Quick codebase orientation. Maps architecture, entry points, and domain models for an unfamiliar repo.
allowed-tools: Read, Grep, Glob, Bash
argument-hint: "[path or leave blank for current repo]"
---

Map this codebase for first contact: $ARGUMENTS

## Instructions

You are orienting in an unfamiliar codebase. Your goal is a concise mental model — not an exhaustive audit. Spend most of your time reading, very little time writing.

### 1. Vital Signs

Gather the basics quickly:
- **Language/framework**: Check for `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, etc.
- **Size**: Count of source files (exclude tests, generated, vendor)
- **Age**: `git log --reverse --format="%ai" | head -1` (first commit)
- **Activity**: `git log --oneline -10` (recent commits)
- **Contributors**: `git shortlog -sn --no-merges | head -5`

### 2. Entry Points

Find how the system starts and what it exposes:
- Main/entrypoint files (`main.*`, `index.*`, `app.*`, `server.*`)
- CLI commands or scripts (`bin/`, `scripts/`, `cmd/`)
- API routes or handlers
- Configuration/bootstrapping

### 3. Domain Models

Identify the core business concepts — the nouns of the system:
- Search for class/struct/type definitions in the main source directory
- Name them in business terms: "This system deals with Orders, Customers, and Invoices"
- Note where they live (are they pure? do they import infrastructure?)

### 4. Architecture Shape

Determine the high-level structure:
- **Monolith or microservice?**
- **Vertical slices, layered, or mixed?**
- **Where does business logic live?** (dedicated domain layer, or scattered?)
- **Where does infrastructure live?** (adapters, or mixed in?)
- **How do modules communicate?** (direct imports, events, API calls?)

### 5. Key Dependencies

Check `package.json`/`pyproject.toml`/`go.mod`/`Cargo.toml` for:
- Framework (Express, FastAPI, Gin, Actix, etc.)
- Database (Prisma, SQLAlchemy, GORM, etc.)
- Major libraries that shape the architecture

### 6. Present the Map

Output a concise orientation document:

```
## Codebase: {name}

**Stack:** {language}, {framework}, {database}
**Size:** ~{N} source files | {lines} LOC
**Shape:** {architecture pattern}

### Domain Models
- {Model1} — {one-line description}
- {Model2} — {one-line description}

### Entry Points
- {file} — {what it does}

### Architecture
{2-3 sentences on how the system is structured}

### First Impressions
- {observation about what's done well}
- {observation about potential concern}
- {question worth investigating}
```

Keep it to one screen. This is a map, not a thesis.

## What This Is NOT

- Not a code review (use `/review` or `/code-review`)
- Not a deep architectural audit (use `/code-review`)
- Not a planning session (use `/cheese` or `/curdle`)
- Not persistent — does not save to `.claude/review/` (use `/code-review` for that)

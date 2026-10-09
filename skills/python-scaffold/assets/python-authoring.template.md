---
name: python-authoring
description: Write, edit, refactor, or review Python in __PROJECT__ with concise, fully typed, stdlib-first code that passes ruff, basedpyright, vulture, and pytest. Use for any Python change under src/ or tests/, especially when the user asks for Pythonic, succinct, de-slopped, dataclass-based, or CLI code.
---

# Authoring Python

Make the smallest readable Python change that satisfies the request and matches __PROJECT__.

This is a repository-local skill. Keep it under `.agents/skills/python-authoring/`. `.claude/skills/python-authoring` is a symlink to it.

## Work in this order

1. Read `pyproject.toml`, the target module, its exports, its immediate callers, and nearby conventions.
2. Trace every changed line to the request. Do not add orchestration, compatibility layers, abstractions, dependencies, or future flexibility.
3. Put code in the package that owns the behavior.
4. Validate untrusted input once at the boundary. After that, use typed trusted data.
5. Choose the clearest succinct construct. Do not compress code until it is harder to read.
6. Remove only slop that the change added and code that the change orphaned.
7. Run `just check`.

## Model and validate data

- Target Python __PYTHON__ and newer. Do not add compatibility code for older versions.
- Prefer the standard library. Add a dependency only when the user approves it, and add it with `uv add`.
- Parse untrusted text with the right parser. Check the container shape, required keys, and value types. Raise a specific error at the boundary.
- Convert validated mappings into frozen dataclasses or domain value types when named fields make the contract clearer.
- Use `TypedDict` only when a mapping must stay a mapping. It does not validate runtime input.
- Use `Enum` or `Literal` for closed value sets. Use `Protocol` only when two or more real types implement it.
- Annotate every function and public method signature. Omit local annotations when inference is clear.

## Write succinct Python

- Use `match` for shape-based dispatch. Use `if` for a binary decision.
- Use a handler mapping for stable command dispatch. Do not make a registry for one or two branches.
- Use comprehensions, generator expressions, `any`, and `all` for pure queries. Keep a loop when it carries state or side effects.
- Use `pathlib`, `enumerate`, f-strings, context managers, `itertools`, and `collections` instead of manual equivalents.
- Catch only named, expected failures. Never use a bare `except`, catch `Exception` to hide it, return an empty default on failure, or use `contextlib.suppress(Exception)`.
- Keep a function at 40 statements or fewer and 4 parameters or fewer. Ruff enforces both limits.
- Keep CLI modules thin: accept `argv`, return an exit status, and write diagnostics to stderr.

## Pass the checkers

- basedpyright runs in `recommended` mode, so warnings fail the gate. Fix the type at its source.
- Assign a deliberately ignored call result to `_` (`reportUnusedCallResult`). Add `@override` to overriding methods (`reportImplicitOverride`).
- Use `cast` only after a runtime check proves the type.
- When a suppression is necessary, use `# pyright: ignore[ruleName]` with a reason. Do not use a bare `# type: ignore` or a file-wide switch.
- basedpyright exit codes: 0 clean, 1 diagnostics, 2 internal error, 3 bad config, 4 bad arguments. Codes 2 to 4 are tool failures, not type findings.
- vulture scans `src/` only, so code that only tests call is dead. Delete it. Add a line to `vulture_whitelist.py` only for a real entry point that vulture cannot see, and write the reason.
- When `.basedpyright/baseline.json` exists, do not add entries to it. Fix new findings.

## Test

- Test observable behavior. Do not write an assertion that passes when the code is broken.
- Keep filesystem tests inside `tmp_path`. Do not use the network, user paths, or state outside the repository.
- pytest runs in strict mode and turns warnings into errors. Register each marker in `pyproject.toml`.
- Group repeated cases with `pytest.mark.parametrize`. Do not add shallow input-variation tests.
- Run the most focused tests first with `just test <path>`, then run `just check`.

## De-slop before finishing

- Delete comments and docstrings that restate the code. Keep non-obvious reasons and public API documentation.
- Remove abstractions with one consumer unless the task needs the seam.
- Name values after domain concepts, not containers or types.
- Fix the cause of a lint finding instead of adding a suppression.

## Completion check

Confirm each item:

- Boundary input is validated once and converted into a trusted type.
- No silent failure, speculative abstraction, narration comment, or unrelated cleanup remains.
- `just check` exits 0.

# Python BDD initial evidence

Checked: 2026-10-10. This record does not score the complete case list.

## Authoring baseline

A fresh agent proposes a ledger BDD plan before the candidate skill exists.
The plan uses real subprocesses, isolated storage, and exact report assertions.
It does not include a deliberate production regression or an installed-wheel check.
Its scenarios include command syntax rather than only domain language.

The baseline is plan-only and inherits the existing agent environment.
It is not an isolated no-skill benchmark or an executed failing suite.
The private transcript is `.context/python-bdd-baseline.md` in the authoring workspace.

## Representative candidate smoke

A fresh coder applies the initial skill to a private, minimal ledger fixture.
The fixture uses uv 0.11.32, CPython 3.13.13, pytest 9.1.1, and pytest-bdd 9.0.0.
It runs a real installed CLI in separate processes against temporary JSON stores.
It uses no mocks or direct database assertions.

| Check | Observed result |
| --- | --- |
| Locked dependency check and sync | Exit 0 |
| Feature collection | Six cases collected |
| BDD suite | Six passed |
| Omitted production persistence write | Focused case fails at the expected external report assertion |
| Restored production write | Focused case passes; full six-case suite passes |
| Wheel build | One wheel built |
| Wheel-installed public CLI outside the source tree | Two adds, four rejected inputs, and five reports pass |
| Hosted CI | Unrun |

The regression changes only the fixture's persistence write.
The failed report contains no entries and total `0.00`, instead of two entries and `19.75`.
Restoration returns the production file to its original content tag.
The wheel smoke removes `PYTHONPATH` and runs in a fresh temporary working directory.

The initial test-first cut fails because the CLI module does not exist.
That missing-module failure is not the regression proof.
An initial build configuration failure also requires an explicit Hatch package path before the successful checks.

## Limits

The smoke is not a completed `CLI-LEDGER` evaluation: its output does not declare currency.
The full eight-case model evaluation remains unrun.
Brownfield preservation, API behavior, routing, and CI execution remain unverified by this smoke.
No speed comparison or statistical improvement claim follows from one generated fixture.

The private evidence lives in `.context/python-bdd-smoke/` and `.context/python-bdd-smoke-report.md`.
The fixture is not distributed with this skill.
Use the frozen setup contracts in `cases.json` for future reproducible evaluations.

Authoring base: `e23764806802d22e3a44dc7a4ac4eaf7331e73a1`.
Initial skill body blob: `a90d5ecf2e06d88592d82f02603a69252f9bc654`.
Initial implementation reference blob: `a8232f29b074848149fc8a60de3c3b003ecad689`.
Restored fixture production blob: `15422f9ea4cc93a81f9ee0f40074e60acf875172`.

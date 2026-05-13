# Sliced Bread Architecture Checks

Per-node checklist for the xray-analyst. Evaluate each rule against the current
node's imports, exports, and position in the dependency graph.

## Checklist

### 1. Cross-slice internal imports

**Rule**: External code imports from index/barrel files only — never reach into
a slice's internals.

**Check**: Scan the node's imports. If any import reaches past a sibling slice's
index file (e.g. `from domains.pricing.discount_calculator import X` instead of
`from domains.pricing import X`), flag it.

**Severity**: Red if the imported internal is not re-exported from the index.
Yellow if it is re-exported but the import bypasses the index anyway.

### 2. Model purity

**Rule**: Domain models import only stdlib, `common/`, and sibling public APIs.
No ORM, framework, or adapter imports.

**Check**: Scan import statements in domain model files. Flag any import from
`adapters/`, `app/`, or external infrastructure packages (database drivers, HTTP
clients, framework internals).

**Severity**: Red — domain-infrastructure coupling is a fundamental violation.

### 3. Dependency direction

**Rule**: Dependencies flow inward: `app/ → domains/ → common/`. Never
`domains/ → adapters/`, `domains/ → app/`, `adapters/ → app/`, or
`common/ → sibling domains`.

**Check**: Map the node's imports against the layer hierarchy. Flag any arrow
pointing outward.

**Severity**: Red for direction violations. These create hidden coupling.

### 4. Growth justification

**Rule**: Every directory and abstraction has 2+ concrete uses. Single
implementations don't need abstractions.

**Check**: If the node is a directory (facade + folder), verify at least 2
files inside. If the node defines an abstract base class, interface, or
protocol, verify 2+ implementations exist.

**Severity**: Yellow — premature abstraction costs complexity but isn't broken.

### 5. Crust integrity

**Rule**: Each slice has an index/barrel file that exposes its public API.
External consumers import from this file.

**Check**: If the node IS a slice root, verify an index file exists. If the
node IMPORTS from a slice, verify it imports from the index.

**Severity**: Yellow if index exists but isn't used. Red if no index exists
and external code reaches into internals.

### 6. Event usage

**Rule**: Events are for reverse dependencies (preventing cycles), not
general-purpose messaging.

**Check**: If the node emits or subscribes to events, verify the event
prevents a dependency cycle. Flag events used between modules that could
use direct imports without creating a cycle.

**Severity**: Yellow — over-eventing adds indirection without benefit.

### 7. Common leaf rule

**Rule**: `common/` is a leaf — it imports nothing from sibling domain slices.

**Check**: If the node is inside `common/`, verify zero imports from sibling
slices (e.g. `domains/orders`, `domains/pricing`).

**Severity**: Red — common depending on a slice creates a cycle.

## How to Report

For each violation found, report:

- **Which check** (by number and name)
- **The specific import or pattern** that violates it
- **Severity** (red/yellow)
- **One-line fix suggestion**

If no violations found for a node, state "Architecture: clean" and move on.

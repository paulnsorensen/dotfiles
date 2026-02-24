# Sliced Bread Architecture — Rationale & Anti-Patterns

Supplement to the compact rules in CLAUDE.md. Read this when reviewing architecture
decisions or planning new domain structure.

## Why Vertical Slices?

Layered architecture (controllers → services → repositories) groups by technical role.
This means a single feature change touches every layer. Vertical slices group by
business concept — an `orders` change stays in `orders/`.

The tradeoff: cross-cutting concerns (auth, logging, caching) live in adapters or
middleware, not sprinkled across slices. If you're tempted to add auth logic inside
a domain slice, that's a signal it belongs in `app/` or `adapters/`.

## Why Organic Growth?

Pre-creating folders, abstract base classes, and registries for a single implementation
is speculative architecture. It costs complexity now for flexibility that may never
be needed. The growth pattern (one file → extract sibling → facade + folder) means
structure emerges from actual pressure, not imagination.

**Growth triggers:**
- A file passes ~200 lines or holds 3+ distinct concepts → extract siblings
- 3+ related files cluster around a sub-concept → create subdirectory
- A file becomes an import hub for its children → it's now a facade

**Not growth triggers:**
- "We might need this later"
- "This looks like it could be its own module"
- A single implementation of a pattern (one adapter, one strategy, one handler)

## Anti-Patterns

### Cross-slice internal imports

```
# BAD — reaching past the crust
from domains.pricing.discount_calculator import DiscountCalculator

# GOOD — import from the public API
from domains.pricing import calculate_discount
```

Why it matters: internal files can be renamed, split, or reorganized freely.
The index/barrel file is a contract; internals are implementation details.

### Domain importing infrastructure

```
# BAD — order.py imports an HTTP client
from adapters.stripe import StripeClient

# GOOD — order.py defines a protocol, adapter implements it
class PaymentGateway(Protocol):
    async def charge(self, amount: Money) -> PaymentResult: ...
```

Why it matters: domain models are the most stable code. Coupling them to
infrastructure means infrastructure changes ripple into business logic.

### Circular dependencies between slices

```
# orders imports pricing, pricing imports orders — cycle
```

Resolution: use domain events. `orders` emits `OrderPlaced`, `pricing` subscribes.
The event lives in `common/events` (the shared kernel) or in the emitting slice's
public API.

### Adapters importing app layer

```
# BAD — adapter depends on a use case or handler
from app.use_cases.checkout import Checkout

# GOOD — adapters only know about domain ports
from domains.orders import OrderRepository
```

Why it matters: adapters implement domain contracts. They shouldn't know how the
application orchestrates those contracts.

### Premature abstraction

```
# BAD — AbstractRepositoryFactory with one concrete implementation
# BAD — EventBus interface when only one event exists
# BAD — PluginRegistry with a single plugin

# GOOD — just use the concrete thing until you need the abstraction
```

## Boundary Decisions

### When does something belong in `common/`?

- Value types used across 2+ slices (Money, UserId, Timestamp)
- Domain events that multiple slices produce or consume
- Shared exceptions or error types

**Not common:** anything used by only one slice. Don't pre-promote to common
"just in case" another slice might need it.

### When do you introduce an adapter?

When domain code needs to talk to something external (database, API, filesystem,
message queue). The domain defines a protocol (port), the adapter implements it.

Don't create an adapter for in-process utilities (string formatting, date math,
pure computation). Those are just functions.

### When does a use case belong in `app/` vs inside a slice?

- **Inside the slice:** operations on a single domain concept (create order,
  update order status). These are domain services or methods on the entity.
- **In `app/use_cases/`:** orchestration across 2+ slices (checkout needs orders +
  pricing + inventory). The use case imports from multiple slice public APIs.

### When do you use events vs direct imports?

- **Direct import:** slice A needs data from slice B to do its work (orders imports
  pricing to calculate totals). This is a natural dependency.
- **Events:** slice B needs to react to something slice A did, but slice A shouldn't
  know about slice B. This prevents cycles and keeps the emitter independent.

Rule of thumb: if adding the import would create a cycle, use an event.

## Dependency Direction Quick-Check

```
app/           →  domains/*     →  domains/common/
adapters/      →  domains/*

Never:
  domains/*    →  adapters/*
  domains/*    →  app/*
  adapters/*   →  app/*
  common/      →  sibling domains
```

## Reviewing Against Sliced Bread

When reviewing code for architecture compliance, check:

1. **Import direction** — do all arrows point inward (toward domains)?
2. **Crust integrity** — are external consumers importing from index files only?
3. **Model purity** — do domain files import only stdlib, common, and sibling public APIs?
4. **Growth justification** — does every directory/abstraction have 2+ concrete uses?
5. **Event usage** — are events used for reverse deps, not passed around as general-purpose messaging?

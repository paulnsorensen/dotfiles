# Self-healing output with a cheap formatter

Read at Flow step 5, or when outputs fail validation.

## Why

An output can pass its schema and still fail a code check.
Refusals, truncation, and enum case drift can also escape the schema [s6].
A rerun of an expensive agent to fix one ID wastes its whole context.

## Route on the error kind

| Validator result | Action | Model |
|---|---|---|
| No errors | Accept the value | none |
| Only `form` errors | Repair: send the object and the errors to a formatter | `haiku`, effort `low` |
| Any `substance` error | Redo: send the original prompt plus the errors to the producer | the producer's tier |
| `null` from a cheap stage | Redo once | the producer's tier |
| `null` from an implementer | Salvage durable state; see `budget-recovery.md` | `haiku` for salvage |

The formatter prompt says three things. Fix only the listed errors. Copy every other field verbatim. Add no new facts.
Give the formatter the same schema as the producer.

## Bounds

1. Put the round limit in code, for example `LIMITS.fixRounds = 2`.
2. Re-run the same validator after each repair. Never trust the formatter.
3. After the limit, return `{ value: null, errors }`. The caller marks the item failed and logs it.
4. Count validation retries apart from transport retries. They are separate knobs [s8].
5. Cap the token cost of a repair loop when the host supports it [s8].

## The typed call

The template function `typed()` in `assets/workflow-template.js` implements this loop. Copy that function; do not retype it.
It validates each value, then repairs `form` errors with a `haiku` formatter or redoes `substance` errors with the producer. It stops after `LIMITS.fixRounds`.
The repair labels are `<label>:repair<round>`. The redo labels are `<label>:redo<round>`.

## Format split

A strong agent can reason better without a schema. Call it without `schema`, then send its text to a `haiku` formatter with the schema.
Use this split only when the reasoning stage is expensive and the schema is large.

## Evidence status

Haiku 4.5 supports structured outputs [s6]. The SDK re-prompts on a schema mismatch [s7].
The research found no primary source that measures Haiku as a repair formatter. Treat this pattern as a design inference. Measure the repair rate in your own runs.

# Agent communication schemas

Read at Flow step 4, or when a review finds free-text fields between stages.

## Rules

1. Give every `agent()` call a `schema`. The Workflow runtime forces a structured-output call and retries on a shape mismatch.
2. Declare each schema as an `UPPER_SNAKE_SCHEMA` constant at the top of the script. Use one constant for one meaning.
3. Use `enum` for each closed set: status, verdict, severity, and check kind. Derive the enum from a shared constant.
4. Give each entity that another stage cites a stable ID, such as `AC-1` or `T-3`. Put a `pattern` on the ID field.
5. Leave fields that cite an ID without a `pattern`. Check those references in code, so the error names the exact fix.
6. Mark every property `required`. Use an empty string or an empty array for "none". Output property order can differ from schema order [s6].
7. Keep reasoning out of the schema. A field that asks for step-by-step reasoning can cause a `reasoning_extraction` refusal [s6]. Ask for a short `evidence` or `note` field.
8. Keep schemas small and flat. Constrained decoding rejects recursion, numeric bounds, length bounds, and `minItems` above 1 [s6]. Enforce those limits in code.
9. Return a digest, not a transcript. Size each output to what the next stage reads.

## Validator contract

The schema checks shape. A code validator checks meaning: cross-field rules, ID references, coverage, and non-empty evidence.

A validator takes the parsed object and returns a list of errors. Each error is `{ kind, msg }`.

- `form` — a mechanical fix with no new facts, such as ID case or a known rename.
- `substance` — a fix that needs new facts or new judgment.

The message names the exact fix. `repair.md` routes each error on `kind`.

```js
function checkVerdict(verdict, ac) {
  const errors = []
  if (verdict.criterion !== ac.id) {
    errors.push(norm(verdict.criterion) === ac.id
      ? form(`criterion '${verdict.criterion}' should be '${ac.id}'`)
      : substance(`verdict is for '${verdict.criterion}', not '${ac.id}'`))
  }
  if (blank(verdict.evidence)) errors.push(substance('evidence must name the check run and its result'))
  return errors
}
```

## Outside the Workflow tool

The Claude API has two separate features: JSON outputs (`output_config.format`) and strict tool use (`strict: true`). You can combine them [s6].
The Agent SDK validates against a JSON Schema and re-prompts on a mismatch. A final failure has the subtype `error_max_structured_output_retries` [s7].
Treat a `refusal` or `max_tokens` stop as a failed output, even with HTTP 200 [s6].

## Anti-patterns

| Pattern | Failure | Fix |
|---|---|---|
| Free-text `status` | Code branches on a string the model invents | `enum` from a shared constant |
| Two schemas with one name | Stages disagree on fields | One constant, imported by meaning |
| Rubric only in the prompt | Verdicts drift between runs | Rubric fields with `enum` values |
| Whole transcript as output | The next stage pays for noise | A digest sized to the reader |

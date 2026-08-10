# BWS 2.1.0 Output Rendering

Bitwarden's `bws` 2.1.0 renderer source, verified 2026-08-06, establishes the exact env-output format that made line-oriented secret parsing unsafe.
Canonical source: [bws 2.1.0 render.rs](https://raw.githubusercontent.com/bitwarden/sdk-sm/bws-v2.1.0/crates/bws/src/render.rs)

## Env renderer behavior

The `Output::Env` renderer emits each secret as `KEY="VALUE"`. It writes the value inside literal double quotes and does not turn a multiline value into a single independently parseable record. A Bash loop that removes only `KEY=` therefore retains the quote, and a physical-line loop truncates a multiline PEM at its first newline.

## JSON renderer behavior

The `Output::Json` renderer delegates serialization to `serde_json`. JSON preserves quote, backslash, equals-sign, and embedded-newline structure, allowing `jq` to select the matching `.key` and emit its `.value`.

## Project relevance

`bin/lib/vault.sh:_vault_fetch_bitwarden` requests env output and `vault_secret_value` parses it line-by-line, stripping one matched surrounding quote pair. This is safe only because all three managed runtime credentials — `CONTEXT7_API_KEY`, `TAVILY_API_KEY`, `TODOIST_API_KEY` — are single-line API keys. `tests/vault.bats:107-159` locks the quoted, unquoted, and interior-quote cases.

The renderer's multiline behavior is therefore a live constraint, not a solved problem: adding any multiline Secret to the project would silently truncate it at the first newline. Switching `_vault_fetch_bitwarden` to `-o json` with structural `jq` selection is the fix if that need returns.

_Source: <https://raw.githubusercontent.com/bitwarden/sdk-sm/bws-v2.1.0/crates/bws/src/render.rs> · Updated: 2026-08-09 · Supersedes: none_

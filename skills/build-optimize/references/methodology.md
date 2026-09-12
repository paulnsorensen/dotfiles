# Local benchmarking and just-parallelism methodology

Use the [Hyperfine README](https://github.com/sharkdp/hyperfine) and [Hyperfine man page](https://github.com/sharkdp/hyperfine/blob/master/doc/hyperfine.1.md) as primary references.

## Hyperfine

Use `--warmup NUM` for a warm workload. Hyperfine runs these iterations before measured runs.

Use `--prepare CMD` for a cold workload. Hyperfine runs this command before each measured timing.

Use `--setup CMD` and `--cleanup CMD` once per benchmark command. They do not run once for an entire multi-command series.

Choose one protocol before collection. Keep the protocol unchanged for every measured row.

Do not add `--warmup` only because an outlier appears. Keep the outlier row and report the selected protocol.

Cold and warm labels describe declared workload layers. They do not describe every operating-system cache.

Use the exact cache-reset command approved by the run plan. Target only an isolated cache directory owned by the run. Configure the workload to use that directory. Do not clear a shared cache or a host-wide cache.

A cache-hit speedup is valid only for the stated warm workload. It is not evidence of a cold rebuild speedup.

## just recipe dependencies

`just` runs recipe dependencies sequentially by default.

Use the [`[parallel]` attribute](https://just.systems/man/en/parallelism.html) only when dependency isolation supports concurrent execution.

Use the installed `just --help` output to select available flags. Do not depend on brittle version numbers.

Preserve the repository's authoritative non-mutating gate. Do not replace it with `just check` when that recipe is absent.

Keep any lint-fix command separate from the verification gate.

Check coverage and required behavior when you assess parity. Do not require identical scheduling.

Treat the [`[cache]` attribute](https://just.systems/man/en/cached-recipes.html) as skip-work caching, not timing evidence.

Do not add speculative cache complexity. Do not add a new justfile or task runner.

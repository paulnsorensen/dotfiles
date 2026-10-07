# Deterministic metrics

A lab metric must give the same value for the same code.
Then a one-percent gain is visible, and CI can gate on it without flakes.

## Choose a count, not a duration

Wall-clock time varies with load, thermal state, and caches.
A count of work varies only with the code.
Use wall-clock time to confirm that a count tracks what users feel. Do not ratchet it.

| Context | Deterministic counts |
| --- | --- |
| Pure JavaScript hot path | CPU instructions under Valgrind with `node --predictable` |
| Browser interaction | React commits, V8 function call counts from coverage, layout and style-recalculation counts, DOM mutations |
| Visual stability | Layout shifts by named region and phase, from the Layout Instability API |
| Animation and streaming | Frames over budget under deterministic frame stepping (8.33 ms at 120 Hz) |
| Native or any process | Instructions from `perf stat -e instructions` or Callgrind `Ir` |
| Python | Call counts from `cProfile` `ncalls`, allocations from `tracemalloc` |
| Service or database | Queries per request, round trips, bytes sent |
| Shell and CLI | Subprocess and syscall counts from `strace -f -c` |
| Build | Executed actions, cache misses, files rebuilt |

These rows are examples. Any count that moves with user latency is valid.

## Benchmark contract

- The benchmark is a command. It prints one number on its last stdout line.
- It fixes inputs, data, seeds, viewport, and frame rate.
- It exits non-zero when the workload fails, so a broken run cannot pass as fast.
- `ratchet.py measure --runs 5` reports `deterministic: true` with tolerance 0.
- A small tolerance is acceptable only for a count with known jitter. Record why in `thread.md`.

## Adoption proof

Adopt a new benchmark only after these checks:

1. **Correlation.** A change that moves the count also moves wall-clock or field latency in the same direction.
2. **Repro.** The benchmark or its test fails on the base revision and passes on the fix. Repeat it, for example 20 of 20 each way.
3. **Coverage.** The benchmark exercises the journey that users run, not a synthetic path only.

## Find more counts

Each new count is a new search space. Census the hot path: hooks, subscriptions, selectors, reloads, clones, and regex paths.
In the source article, a census found 6,900 hooks in one typing path, and a string scan found a UTF-16 regex slow path.
Add telemetry or a guardrail when you find a new class of waste. Each one opens more threads.

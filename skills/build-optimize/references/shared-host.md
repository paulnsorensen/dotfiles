# Shared-host parallelism

Use this reference when several agents, worktrees, or benchmarks run gates on one host.
A worker count that is fastest for one gate can overload a shared host.

## Failure mode

- `pytest -n auto` starts one worker for each core in each worktree.
  Five agents on a 24-core host can start 120 test workers.
- The Linux scheduler shares CPU by thread, not by job.
  A gate with 24 workers gets about six times the CPU of a gate with 4 workers.
- A gate that runs lanes concurrently adds its lane processes to its own worker count.
- A launcher script without a lock can start the same long run twice.
  Two runs that share one output file or one budget can corrupt results or count spend twice.

Diagnose with `uptime`, `nproc`, `vmstat 1 3`, and `ps -eo pid,ppid,etime,%cpu,args --sort=-%cpu`.
Compare the 1-, 5-, and 15-minute load averages with the core count.
High load with near-zero I/O wait and free memory means CPU oversubscription.
Group the top processes by parent PID and working directory to find the owning job.

## Controls

Use these controls together. Each control solves a different part of the problem.

| Control | Effect | Limit |
| --- | --- | --- |
| Per-job cgroup | Equal CPU share for each job | Does not reduce the process count |
| Load-aware worker count | Fewer workers when the host is busy | Reads load once, at start |
| Machine-wide queue | At most N heavy jobs at once | Counts jobs, not cores |
| Run lock | One run for each output or budget | Protects one resource only |
| Shared jobserver | One token pool for all builds | Build tools only; not tested here |

### Per-job cgroup

Start each heavy job in its own cgroup scope. The kernel then shares CPU between jobs, not between threads. [systemd.resource-control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html)

```bash
systemd-run --user --scope -q -p CPUWeight=100 -- just check
```

Use a lower `CPUWeight` for batch work, such as benchmarks, so interactive work stays fast.
This control needs cgroup v2 with the `cpu` controller and a systemd user manager.
On macOS, use `nice -n 10` instead.

### Load-aware worker count

pytest-xdist calls the `pytest_xdist_auto_num_workers` hook to resolve `-n auto`. [xdist how-to](https://pytest-xdist.readthedocs.io/en/stable/how-to.html)
A `conftest.py` hook can size the pool from the free cores:

```python
import os


def pytest_xdist_auto_num_workers(config):
    pinned = os.environ.get("PYTEST_XDIST_AUTO_NUM_WORKERS")
    if pinned:
        return int(pinned)
    cpus = os.cpu_count() or 1
    free = cpus - os.getloadavg()[0]
    cap = int(os.environ.get("TEST_WORKERS_MAX", cpus))
    return max(2, min(cap, int(free)))
```

A `conftest.py` hook overrides the `PYTEST_XDIST_AUTO_NUM_WORKERS` environment variable.
Read the variable in the hook, as shown, so an explicit pin still works.
The worker count does not change after the run starts.

For Rust, cargo and nextest have no load option.
Compute the count in the recipe and pass `cargo build -j N` or `cargo nextest run --test-threads N`.

### Machine-wide queue

GNU `sem` gives one counted queue to all processes that use the same `--id`. [sem](https://www.gnu.org/software/parallel/sem.html)

```bash
sem --id heavy -j 3 --load 80% --fg just check
```

- `-j 3` runs at most three jobs with this id at once.
- `--load 80%` starts a job only when the load is below 80% of the cores.
- `--fg` keeps the job attached, so the caller gets the exit code and output.
- `--semaphoretimeout` sets how long a job waits for a slot.

Waiting jobs poll for a free slot. The queue is not first-in, first-out.

### Load-gated just lanes

GNU `parallel` can run just recipes as lanes. It holds back new lanes while the load is high. [parallel](https://www.gnu.org/software/parallel/man.html)

```just
check:
    parallel --load 80% --halt now,fail=1 --tag --line-buffer just ::: lint typecheck test
```

The just [`[parallel]` attribute](https://just.systems/man/en/parallelism.html) runs dependencies concurrently.
It has no load gate and no job limit.
Use `--halt soon,fail=1` when the report must show every failing lane.

### Run lock

Take a lock keyed on the shared resource, such as an output path or a budget id.
Put the lock in the program that owns the resource, not only in a launcher script.

```bash
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/bench-${BUDGET_ID}.lock"
flock -n 9 || { echo "run ${BUDGET_ID} is active" >&2; exit 75; }
```

### Shared jobserver

GNU Make 4.4 can share a token pool through a named pipe. [Make jobserver](https://www.gnu.org/software/make/manual/html_node/POSIX-Jobserver.html)
Cargo and rustc act as jobserver clients for builds.
Test runners such as pytest-xdist and nextest do not take tokens.
Treat a cross-process fifo jobserver as untested until a measured run confirms it.

## Measurement

Measure a fleet recommendation under concurrent load.
Run the gate in K worktrees at once, where K is the expected agent count.
Report the slowest gate time and the total wall time for each worker policy.
A single-gate speedup is not evidence for a shared host.

## Local evidence (2026-10-17)

These results come from a 24-core Linux host with cgroup v2:

- The xdist hook created 19 workers at a load of 4.8, 3 workers with `TEST_WORKERS_MAX=3`, and 5 workers with `PYTEST_XDIST_AUTO_NUM_WORKERS=5`.
- Before the hook read the variable, `PYTEST_XDIST_AUTO_NUM_WORKERS=5` still created 18 workers.
- `systemd-run --user --scope -p CPUWeight=50` placed the job in its own scope with `cpu.weight` 50.
- Two `sem --id` jobs with `-j1` from separate processes ran in sequence.
- `sem --load 1%` held a job for more than three seconds.
- just 1.58 `[parallel]` ran two one-second recipes in 1.02 seconds; `parallel --load 80%` took 1.60 seconds.
- A second `flock -n` on a held lock file failed at once.

# `curl: (23)` during omp install is `ETXTBSY`, not a network fault

The omp.sh installer curls its release asset **straight onto the live binary path**. If an `omp` session is running, the kernel refuses the write with `ETXTBSY` and curl reports:

```
curl: (23) client returned ERROR on write
```

which reads like a transfer failure and sends you looking at the network. It isn't. Nothing is wrong with the download.

## The mechanism

A running process holds its executable open **for execution**, and the kernel refuses to let anyone open that same inode *for writing* — that is what `ETXTBSY` means. The direction matters and is easy to state backwards: it is not that the process holds a write lock; it is that the process's execution blocks *your* write.

This is also why the failure is specific to compiled binaries. #677's test note records the distinction: an interpreted script is only held open for *reading*, so overwriting one in place never trips this.

## The fix: stage, then rename

`converge_omp_native` (`packages/sync.sh:743-780`) downloads into a staging dir and moves the result into place:

```sh
stage_dir="$HOME/.local/bin/.omp-stage"   # packages/sync.sh:819
...
mv -f "$staged" "$HOME/.local/bin/omp"    # packages/sync.sh:776
```

`rename(2)` swaps the **directory entry**, never opening the running binary's inode. Already-running processes keep executing the old inode until they exit; the next launch picks up the new one. No `ETXTBSY`, and no need to ask the user to quit omp first.

The staging dir must stay on the **same filesystem** as the target, or `mv` degrades to copy-and-delete and the whole point is lost. `$HOME/.local/bin/.omp-stage` is a child of the install dir, which guarantees it.

Two smaller details in that function, both deliberate:

- The stage dir is put on `PATH` during the install (`packages/sync.sh:747-751`) purely so the installer doesn't close by telling the user to add a directory that is deleted seconds later.
- The installer's own smoke test runs against the still-unsigned download and fails, so the signed binary is **re-checked** rather than trusting the installer's exit status (`packages/sync.sh:764-767`).

Landed in #677.

Related: [[operations/mise-manifest-precedence]] and [[operations/mise-github-auth]] (the other two failures from the same investigation — all three made `dots sync` fail for reasons that looked unrelated to the actual defect), [[operations/sync-and-chezmoi]].

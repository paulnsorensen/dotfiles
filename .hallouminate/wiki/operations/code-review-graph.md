# code-review-graph: embeddings backend + the parse-pool leak

`code-review-graph` (CRG) is the structural knowledge-graph MCP (`agents/mcp/registry.yaml`). Two non-obvious things about running it on this stack: its embedding backend is needlessly heavy by default, and its parse worker pool leaks orphaned processes on Linux MCP hosts. Both are fixed in the registry entry.

## The default embeddings backend is wrong for a no-CUDA box

`--from code-review-graph[embeddings]` pulls `sentence-transformers` → `torch`. On Linux x86_64, pip/uv resolve `torch` to the **CUDA wheel** (~2.4 GB; drags in `nvidia-cublas/cufft/cusolver/cusparselt-cu13`…). On an AMD box with no NVIDIA GPU that is pure dead weight — embeddings still run on CPU, just via the heaviest possible install. The default model is `all-MiniLM-L6-v2` (384-dim), downloaded from HF Hub on first use — the first-run "hang". `<certain>` (`embeddings.py` `LOCAL_DEFAULT_MODEL`)

`semantic_search_nodes_tool` and the embed phase of `build_or_update_graph_tool` are the only embedding-dependent surfaces; the other ~12 tools are pure tree-sitter structure and need no model.

## On a local-LLM machine: reuse local-embed, drop torch

When the [[local-llm]] stack is present (chezmoi `localLLM=true`), CRG reuses the resident **Qwen3-Embedding-0.6B** (`local-embed`, hot/always-resident) instead of torch. The registry entry gates on `localLLM`:

- `localLLM=true` → `--from code-review-graph` (no `[embeddings]`, no torch, no HF download) + `CRG_OPENAI_BASE_URL`/`_API_KEY`/`_MODEL` pointing at the embed server.
- otherwise → keep `[embeddings]` + the default local provider (prior behavior).

The gate is a per-value Go template in the registry: `{{ if get . "localLLM" }}…`. This is the **first use of chezmoi `[data]` (not just `env "HARNESS"`) in the MCP registry** — it works because `ap`'s renderer shells each value through `chezmoi execute-template` (`agent-profile/agent_profile/templating.py` `render_value`), which loads the machine's persisted chezmoi data. Use `get . "localLLM"`, not a bare `.localLLM`: chezmoi renders with `missingkey=error`, so a machine whose `chezmoi.toml` predates the flag would error on a bare reference (same rule the `.chezmoiignore` `localLLM` gate uses). See [[../architecture/mcp-secret-handling]] for how registry values are carried/rendered.

### Point at llama-swap :9000, NOT LiteLLM :4000

CRG must hit **llama-swap directly (`http://127.0.0.1:9000/v1`)**, not the LiteLLM proxy (`:4000`). `<certain>` After CRG embeds once it auto-learns the dimension and then sends a `dimensions` param on every subsequent request (`embeddings.py` `_call_api`: `if self._dimension is not None: body["dimensions"] = …`). LiteLLM **rejects `dimensions` for an `openai/` model with `UnsupportedParamsError` even though `drop_params: true` is set** in `litellm.yaml` — so the graph *build* (batch embed) 400s. llama-swap's raw llama.cpp endpoint accepts the param.[^crg-dim] `local-embed` is in llama-swap's hot group, so `:9000` has no cold-swap latency.

`CRG_ACCEPT_CLOUD_EMBEDDINGS` is unnecessary for a localhost base URL — CRG only emits the cloud-egress warning when the URL is non-localhost (`_warn_cloud_egress` is skipped for `127.0.0.1`).

### Provider is per-call; the default is "local"

There is **no env var or `serve` flag to default the provider to "openai"** `<certain>` — `cli.py` has zero `provider` tokens, and the `@mcp.tool` functions declare `provider: Optional[str] = None` → `get_provider(None)` → local (`main.py`, `embeddings.py` `get_provider`). So with `[embeddings]` dropped, an agent **must** call `build_or_update_graph_tool` / `semantic_search_nodes_tool` with `provider="openai"`, `model="local-embed"`; the default `local` path has no sentence-transformers and errors. That is why `agents/preamble.md`'s code-review-graph section carries the provider note. Switching provider/model re-embeds the graph automatically — CRG partitions the `embeddings` table by provider identity (`openai:local-embed@<host>`), so the 384→1024-dim change is additive, not corrupting.

## The parse-pool leak (all machines)

CRG parses with a `ProcessPoolExecutor` of `CRG_PARSE_WORKERS=min(cpu_count, 8)` workers. On a Linux MCP/stdio host, when the server is killed (session end) those workers **orphan to init** — the classic leaked-daemon pile (observed: dozens of stale `code-review-graph serve` procs up to ~11 days old, an 8-worker group reparented to `ppid=1`). CRG's own code knows about this (issues #46/#136) but only auto-switches to a thread pool on **Windows** — `incremental.py` `_select_executor_kind` gates the switch on `sys.platform == "win32"`; Linux falls through to `process` and leaks. `<certain>`

**Fix:** `CRG_PARSE_EXECUTOR=thread` in the registry env (set unconditionally, both branches). Tree-sitter releases the GIL during native parsing, so the speed cost is small (<30% per CRG's own docstring) and no orphanable subprocess is created. Independent of the embedding backend — this leak existed regardless of provider. Cf. the retired serena-mux leaked-daemon problem in [[../architecture/config-drift]].

## Reaping stale servers

Until every session has restarted onto the thread-executor config, legacy `process`-pool servers may linger. Inspect first — this machine aliases `ps`→`procs` (the Rust tool), so use `pgrep`/`pkill` (or `/usr/bin/ps`):

    pgrep -a --older 3600 -f 'code-review-graph serve'

Kill the stale ones (older than 1 h = 3600 s, sparing active sessions). `--older` needs procps-ng ≥ 4.x:

    pkill --older 3600 -f 'code-review-graph serve'

Nuke everything (kills active sessions' servers too — they respawn on next use): `pkill -f 'code-review-graph serve'`. With `CRG_PARSE_EXECUTOR=thread` deployed, restart sessions and the orphan-worker leak stops at the source — reaping becomes a one-time cleanup of the legacy pile, not a recurring chore.

[^crg-dim]: Reproduced 2026-06-24: `curl :4000/v1/embeddings` with `{"model":"local-embed","dimensions":1024}` → `litellm.UnsupportedParamsError`; the same payload to `:9000` → `2×1024` OK. The full CRG `OpenAIEmbeddingProvider` path (`embed_query` + batch `embed`) succeeds against `:9000` and 400s against `:4000`.

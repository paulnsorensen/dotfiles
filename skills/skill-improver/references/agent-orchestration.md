# Pack: agent-orchestration

# target_param: {SKILL}        (the skill whose orchestration we audit)

# harness: harness='all' (agent_spawns / mcp_calls are claude-dominant — note that)

# owner: skill-improver

What `{SKILL}` actually does after it fires: which tools, agents, and MCPs it
drives in the 10-minute window after each invocation. Run by `duckdb-expert`,
one spawn. Schema: `skills/session-analytics/references/canonical-schema.md`.

## 1. Tools used within 10-minute windows after invocation

```sql
WITH w AS (
    SELECT sessionId, timestamp::TIMESTAMP AS t0,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t1
    FROM skill_invocations WHERE skill_name = '{SKILL}'
)
SELECT tu.tool_name, count(*) AS uses
FROM tool_uses tu JOIN w ON tu.sessionId = w.sessionId
    AND tu.timestamp::TIMESTAMP BETWEEN w.t0 AND w.t1
GROUP BY tu.tool_name ORDER BY uses DESC;
```

## 2. Agent types spawned during windows

```sql
WITH w AS (
    SELECT sessionId, timestamp::TIMESTAMP AS t0,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t1
    FROM skill_invocations WHERE skill_name = '{SKILL}'
)
SELECT asp.agent_type, substr(asp.description, 1, 80) AS desc, asp.mode,
       count(*) AS spawns
FROM agent_spawns asp JOIN w ON asp.sessionId = w.sessionId
    AND asp.timestamp::TIMESTAMP BETWEEN w.t0 AND w.t1
GROUP BY asp.agent_type, desc, asp.mode ORDER BY spawns DESC;
```

## 3. MCP servers called during windows

```sql
WITH w AS (
    SELECT sessionId, timestamp::TIMESTAMP AS t0,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t1
    FROM skill_invocations WHERE skill_name = '{SKILL}'
)
SELECT split_part(mc.tool_name, '__', 2) AS server,
       split_part(mc.tool_name, '__', 3) AS method, count(*) AS calls
FROM mcp_calls mc JOIN w ON mc.sessionId = w.sessionId
    AND mc.timestamp::TIMESTAMP BETWEEN w.t0 AND w.t1
GROUP BY server, method ORDER BY calls DESC;
```

## 4. Parallel-spawn shape (fan-out width per invocation)

```sql
WITH w AS (
    SELECT sessionId, timestamp AS inv_ts, timestamp::TIMESTAMP AS t0,
           timestamp::TIMESTAMP + INTERVAL '10' MINUTE AS t1
    FROM skill_invocations WHERE skill_name = '{SKILL}'
)
SELECT w.sessionId, w.inv_ts, count(*) AS agents_spawned
FROM agent_spawns asp JOIN w ON asp.sessionId = w.sessionId
    AND asp.timestamp::TIMESTAMP BETWEEN w.t0 AND w.t1
GROUP BY w.sessionId, w.inv_ts ORDER BY agents_spawned DESC LIMIT 10;
```

## Output Format

```
## Orchestration Analytics: {SKILL}

### Tool Usage (post-invocation windows)
| Tool | Uses |
|------|------|

### Agent Spawns
| Agent Type | Description | Mode | Count |
|------------|-------------|------|-------|

### MCP Usage
| Server | Method | Calls |
|--------|--------|-------|

### Fan-out Shape
- Typical agents spawned per invocation: N
- Widest fan-out: N (session …)

### Findings
- [Declared-vs-actual tool/agent/MCP mismatches, surprising delegations]
```

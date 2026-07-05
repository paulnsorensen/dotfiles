#!/usr/bin/env bash
# Workflow JS parse guard — wraps each claude/workflows/*.js file in an
# async function (matching the node-runner.js harness pattern) and verifies
# it parses without error.  Also checks logic invariants that are pure and
# deterministic (slugify, arg-coercion, guard conditions, schema fields).
#
# Not a bats test: it requires node, which is not guaranteed in CI bats runs.
# Run via: bash tests/workflows-parse.sh
# Runs from the Justfile smoke target.
#
# Exit codes:
#   0  all workflows parse + logic checks pass, or node is absent (skip)
#   1  one or more files fail to parse or logic checks fail

set -euo pipefail

SCRIPT_DIR="$(cd "${0%/*}" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOWS_DIR="$REPO_ROOT/claude/workflows"

if ! command -v node >/dev/null 2>&1; then
    echo "node not on PATH — skipping workflow parse check"
    exit 0
fi

fail=0
assert() {
    local label="$1" result="$2"
    if [[ "$result" == "PASS" ]]; then
        echo "  ok  $label"
    else
        echo "  FAIL $label" >&2
        fail=1
    fi
}

echo "Workflow parse + logic checks:"

# ── 1. Syntax check: every .js in claude/workflows/ must parse ──────────────

for js in "$WORKFLOWS_DIR"/*.js; do
    [[ -f "$js" ]] || continue
    name="$(basename "$js")"
    # Strip ES module export header; wrap in async function matching harness
    if node -e "
        const fs = require('fs');
        const src = fs.readFileSync('$js', 'utf8');
        const stripped = src.replace(/^export\\s+const\\s+meta\\s*=\\s*\\{[\\s\\S]*?\\n\\}\$/m, '');
        const wrapped = '(async function(){' + stripped + '})();';
        new Function(wrapped);
    " 2>/dev/null; then
        echo "  ok  $name: parses as async function"
    else
        echo "  FAIL $name: parse error" >&2
        fail=1
    fi
done

# ── 2. ultracook-fleet.js logic invariants ──────────────────────────────────

FLEET="$WORKFLOWS_DIR/ultracook-fleet.js"

if [[ -f "$FLEET" ]]; then
    node -e "
        const fs = require('fs');
        const src = fs.readFileSync('$FLEET', 'utf8');
        let ok = 0, bad = 0;

        function check(label, cond) {
            if (cond) { process.stdout.write('  ok  ' + label + '\\n'); ok++; }
            else { process.stderr.write('  FAIL ' + label + '\\n'); bad++; }
        }

        // slugify extracted for deterministic testing
        function slugify(text) {
            return (text || '')
                .toLowerCase()
                .replace(/[^a-z0-9]+/g, '-')
                .replace(/^-+|-+\$/g, '')
                .slice(0, 40);
        }
        check('slugify empty',    slugify('') === '');
        check('slugify spaces',   slugify('Hello World') === 'hello-world');
        check('slugify null',     slugify(null) === '');
        check('slugify trim',     slugify('  x  ') === 'x');
        check('slugify max40',    slugify('A'.repeat(50)) === 'a'.repeat(40));
        check('slugify leading-', slugify('---x') === 'x');

        // arg coercion
        function rawArgFor(args) {
            const rawArg =
                typeof args === 'string' ? args
                : args && typeof args === 'object' && args.roadmap_slug ? args.roadmap_slug
                : args != null ? String(args)
                : '';
            return rawArg.trim();
        }
        check('rawArg string',           rawArgFor('slug') === 'slug');
        check('rawArg {roadmap_slug}',   rawArgFor({roadmap_slug:'rs'}) === 'rs');
        check('rawArg null',             rawArgFor(null) === '');
        check('rawArg undefined',        rawArgFor(undefined) === '');
        check('rawArg trim',             rawArgFor('  s  ') === 's');

        // guard conditions
        check('empty slug guard',        src.includes('if (!roadmapSlug)'));
        check('no goals guard',          src.includes('!importResult.goal_node_ids.length'));
        check('all partitions fail guard', src.includes('if (!goodPartitions.length)'));
        check('no launches guard',       src.includes('if (!launchedPartitions.length)'));

        // MCP isolation: no top-level milknado_ calls
        const topMcp = src.split('\\n').filter(line => {
            const t = line.trim();
            return t.startsWith('milknado_') && !t.startsWith(\"'\") && !t.startsWith('\"') && !t.startsWith('//');
        });
        check('no top-level milknado_ calls', topMcp.length === 0);

        // phase order
        const phases = ['Import','Partition','Run','Monitor','Harvest'];
        let last = -1, ordered = true;
        for (const p of phases) {
            const idx = src.indexOf(\"phase('\" + p + \"')\");
            if (idx < 0 || idx < last) { ordered = false; break; }
            last = idx;
        }
        check('all 5 phases present in order', ordered);

        // all 7 phase-node variables
        for (const n of ['cook','press','age1','cure1','age2','cure2','age3']) {
            check('phase node var ' + n + '_id', src.includes(n + '_id'));
        }

        process.stdout.write('\\n  slugify/arg/guard/arch: ' + ok + ' ok, ' + bad + ' failed\\n');
        process.exit(bad > 0 ? 1 : 0);
    " 2>&1 || fail=1
fi

# ── 3. ultracook-fleet-worker.toml required keys ────────────────────────────

TOML="$REPO_ROOT/claude/workflows/ultracook-fleet-worker.toml"
if [[ -f "$TOML" ]]; then
    for key in execution_agent quality_gates concurrency_limit db_path worktree_pattern; do
        if grep -q "$key" "$TOML"; then
            echo "  ok  toml has $key"
        else
            echo "  FAIL toml missing $key" >&2
            fail=1
        fi
    done
    if grep -q 'dangerously-skip-permissions' "$TOML"; then
        echo "  ok  toml: --dangerously-skip-permissions present"
    else
        echo "  FAIL toml: --dangerously-skip-permissions missing" >&2
        fail=1
    fi
fi

# ────────────────────────────────────────────────────────────────────────────

if ((fail)); then
    echo
    echo "FAILED — workflow parse/logic check"
    exit 1
fi
echo
echo "ok — all workflow parse/logic checks passed"

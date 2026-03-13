/**
 * block-inline-tests.js
 *
 * Prevents Claude from writing `python3 -c "..."` inline test scripts.
 * These patterns bypass project venv, pytest fixtures, conftest, and leave no test artifact.
 *
 * Detected patterns:
 * - python3 -c 'import X; assert ...'
 * - python3 -c "import X; print(...)"
 * - python3 -c $'...\n...' (heredoc form)
 * - cat << 'EOF' | python3 -c "..." (piped heredoc)
 * - python3 -c < file.py (file redirect)
 *
 * Does NOT block legitimate one-liners like:
 * - python3 -c "print(sys.version)"
 * - python3 -c "import json; print(json.dumps({}))"
 *
 * Redirects to: /test-sandbox skill or uv run pytest
 */

module.exports = {
  event: 'preToolUse',
  hooks: [
    {
      matcher: (toolName, input) => {
        if (toolName !== 'Bash') return false;

        const cmd = input.command || '';

        // Pattern 1: python3? -c with import + assert or print(
        // This catches test-flavored patterns without blocking legitimate one-liners
        const testPattern =
          /python3?\s+-c\s+['"].*\bimport\b.*(?:\bassert\b|print\s*\()/;
        if (testPattern.test(cmd)) return true;

        // Pattern 2: python3? -c with heredoc ($'...' form)
        // Heredoc is often used for multi-line test scripts
        const heredocPattern = /python3?\s+-c\s+\$'/;
        if (heredocPattern.test(cmd)) return true;

        // Pattern 3: Multi-line python3 -c with semicolon-separated imports + assertions
        // Catches: python3 -c "from x import y; z = something; assert z == expected"
        const multilinePattern = /python3?\s+-c\s+['"][^'"]*\bimport\b[^'"]*;[^'"]*(?:\bassert\b|print\s*\()/;
        if (multilinePattern.test(cmd)) return true;

        // Pattern 4: cat/python3 piped with heredoc containing test patterns
        // Catches: cat << 'EOF' | python3 -c "..." or python3 -c < heredoc.py
        // Also: cat <<-EOF (with tab stripping)
        const heredocPipePattern = /(?:cat\s+<<[-~]?|python3?\s+-c\s*<\s*)['"]?\w+/;
        if (heredocPipePattern.test(cmd) && /\bimport\b.*(?:\bassert\b|print\s*\()/.test(cmd)) return true;

        return false;
      },

      handler: async (_toolName, input) => {
        return {
          result: `Blocked: python3 -c with test pattern (import + assert/print)

This pattern bypasses your project's venv, pytest fixtures, and conftest configuration.
It produces no test artifact and leaves no CI record.

Use the /test-sandbox skill instead:
  /test-sandbox "assert my_module.fn() == expected"

Or write a proper test file:
  uv run pytest tests/test_feature.py --tb=short

To override this block, use git commit --no-verify (not recommended).`
        };
      }
    }
  ]
};

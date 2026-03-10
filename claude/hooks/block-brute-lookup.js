// block-brute-lookup.js
// Blocks brute-force code lookup and build output parsing patterns
// Part of the Cheddar Flow enforcement system
//
// Two categories of anti-patterns:
//
// 1. LOOKUP: grepping dependency caches, doc gen + grep, find chains
//    → Use /lookup skill (routes to LSP, Serena, ast-grep, Context7, octocode)
//
// 2. BUILD OUTPUT: piping build commands through tail/head/grep to parse errors
//    → Use /make skill (forked subagent, structured file:line:col output)
//
// Language-agnostic coverage:
// Rust:   cargo doc/check + grep, ~/.cargo/registry/, target/doc/
// JS/TS:  node_modules/, .pnpm-store/, npm run build | tail
// Python: site-packages/, .venv/lib/, python help(), mypy | grep
// Go:     go doc + grep, $GOPATH/pkg/mod/, go build | tail
// Ruby:   gems/, .gem/
// Java:   .m2/repository/, .gradle/caches/

// Dependency cache paths — any grep/cat/find touching these is a brute-force lookup
const DEP_CACHE_PATTERNS = [
  /\.cargo\/registry/,
  /node_modules\//,
  /\.pnpm-store/,
  /site-packages\//,
  /\.venv\/lib\//,
  /\/go\/pkg\/mod\//,
  /GOPATH.*pkg\/mod/,
  /\.m2\/repository\//,
  /\.gradle\/caches\//,
  /\.gem\//,
  /vendor\/bundle\//,
];

// Doc generation commands used for grepping (not legitimate doc builds)
const DOC_GREP_PATTERNS = [
  { gen: /cargo\s+doc\b/, label: 'cargo doc' },
  { gen: /go\s+doc\b/, label: 'go doc' },
  { gen: /pydoc3?\b/, label: 'pydoc' },
  { gen: /python3?\s+-c\s+.*help\s*\(/, label: 'python help()' },
  { gen: /ri\s+/, label: 'ri (Ruby)' },
];

// Build commands — when piped through tail/head/grep, use /make instead
const BUILD_CMD_PATTERNS = [
  /cargo\s+(check|build|clippy|test)\b/,
  /npm\s+run\s+(build|check|lint|test)\b/,
  /npx\s+tsc\b/,
  /bun\s+(build|test)\b/,
  /go\s+(build|test|vet)\b/,
  /just\s+(check|build|test|lint|ci)\b/,
  /make\s+(check|build|test|lint|all)?\b/,
  /cmake\s+--build\b/,
  /gradle\w*\s+(build|test|check)\b/,
  /mvn\s+(compile|test|verify)\b/,
  /uv\s+run\s+(mypy|pytest|ruff)\b/,
  /mypy\b/,
  /pytest\b/,
  /ruff\s+check\b/,
  /eslint\b/,
  /tsc\s+--noEmit\b/,
];

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Bash') return false;
      const cmd = input.command || '';

      // Block build commands piped through tail/head/grep for output parsing
      const hasParsePipe = /\|\s*(tail|head|grep)\b/.test(cmd);
      if (hasParsePipe) {
        for (const pattern of BUILD_CMD_PATTERNS) {
          if (pattern.test(cmd)) return true;
        }
      }

      // Block doc generation when chained with grep/head/tail (lookup, not doc build)
      for (const { gen } of DOC_GREP_PATTERNS) {
        if (gen.test(cmd) && /grep|head|tail/.test(cmd)) return true;
      }

      // Block grepping dependency caches
      for (const pattern of DEP_CACHE_PATTERNS) {
        if (pattern.test(cmd)) return true;
      }

      // Block grepping generated doc directories
      if (/target\/doc\//.test(cmd) && /grep/.test(cmd)) return true;

      // Block find + xargs/exec grep chains for type/signature lookup
      if (/find\s+.*-exec\s+grep/.test(cmd)) return true;
      if (/find\s+.*\|\s*xargs\s+grep/.test(cmd)) return true;

      return false;
    },
    handler: async (_toolName, input) => {
      const cmd = input.command || '';

      // Check for build output parsing first (most common anti-pattern)
      const hasParsePipe = /\|\s*(tail|head|grep)\b/.test(cmd);
      if (hasParsePipe) {
        for (const pattern of BUILD_CMD_PATTERNS) {
          if (pattern.test(cmd)) {
            const buildCmd = cmd.match(pattern)?.[0] || 'build command';
            return {
              result: `Blocked: piping ${buildCmd} through tail/head/grep to parse output.
  Use /make instead — it runs the build in a forked subagent and returns
  structured file:line:col errors. Zero context pollution, zero noise.
  Example: /make (auto-detects build system) or /make test`
            };
          }
        }
      }

      // Identify which doc tool was used
      for (const { gen, label } of DOC_GREP_PATTERNS) {
        if (gen.test(cmd)) {
          return {
            result: `Blocked: ${label} + grep for symbol lookup. Use code intelligence tools instead:
  - LSP hover: instant type/signature info on any symbol in your code
  - Context7: resolve-library-id → query-docs for versioned API docs
  - octocode: search the package's GitHub repo for implementations
  - /lookup skill: routes you to the right tool automatically`
          };
        }
      }

      // Identify which dependency cache was hit
      for (const pattern of DEP_CACHE_PATTERNS) {
        if (pattern.test(cmd)) {
          const match = cmd.match(pattern);
          return {
            result: `Blocked: grepping dependency cache (${match[0]}) for symbol lookup.
  - LSP hover: type/signature of any symbol where you use it (zero config)
  - Context7: resolve-library-id → query-docs for versioned API docs
  - octocode: search the package's GitHub repo
  - /lookup skill: routes you to the right tool automatically`
          };
        }
      }

      if (/target\/doc\//.test(cmd)) {
        return {
          result: `Blocked: grepping generated docs. Use Context7 or LSP hover instead.
  - LSP hover on the symbol in your code gives the same info instantly
  - Context7 query-docs returns versioned API documentation`
        };
      }

      return {
        result: `Blocked: find + grep chain for code lookup. Use code intelligence tools:
  - Serena find_symbol: locate symbols by name with cross-references
  - ast-grep (sg): structural pattern matching (via /trace skill)
  - LSP documentSymbol: list all symbols in a file
  - /lookup skill: routes you to the right tool automatically`
      };
    }
  }]
};

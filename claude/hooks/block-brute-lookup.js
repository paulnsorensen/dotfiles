// block-brute-lookup.js
// Blocks brute-force code lookup patterns — agents should use code intelligence tools
// Part of the Cheddar Flow enforcement system
//
// cargo doc + grep → Context7 or octocode for external crate docs
// grep ~/.cargo/registry/ → LSP hover or Context7
// grep node_modules/ → LSP hover or Context7
// find + grep for signatures → Serena find_symbol or LSP hover

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Bash') return false;
      const cmd = input.command || '';

      // Block cargo doc when used for lookup (not legitimate doc generation)
      if (/cargo\s+doc\b/.test(cmd) && /grep|head|tail/.test(cmd)) return true;

      // Block grepping dependency caches
      if (/\.cargo\/registry/.test(cmd)) return true;
      if (/node_modules\//.test(cmd) && /(grep|cat|head|find)/.test(cmd)) return true;

      // Block grepping target/doc/ (generated docs)
      if (/target\/doc\//.test(cmd) && /grep/.test(cmd)) return true;

      // Block find + xargs/exec grep chains for type/signature lookup
      if (/find\s+.*-exec\s+grep/.test(cmd)) return true;
      if (/find\s+.*\|\s*xargs\s+grep/.test(cmd)) return true;

      return false;
    },
    handler: async (_toolName, input) => {
      const cmd = input.command || '';

      if (/cargo\s+doc\b/.test(cmd)) {
        return {
          result: `Blocked: cargo doc + grep for symbol lookup. Use code intelligence tools instead:
  - LSP hover: instant type/signature info on any symbol in your code
  - Context7: query-docs for external crate documentation
  - octocode: search the crate's GitHub repo for implementations
  - /lookup skill: routes you to the right tool automatically`
        };
      }

      if (/\.cargo\/registry/.test(cmd) || /node_modules\//.test(cmd)) {
        const cache = /\.cargo\/registry/.test(cmd) ? 'cargo registry' : 'node_modules';
        return {
          result: `Blocked: grepping ${cache} for symbol lookup. Use code intelligence tools instead:
  - LSP hover: type/signature of any symbol where you use it (zero config)
  - Context7: resolve-library-id → query-docs for versioned API docs
  - octocode: search the package's GitHub repo
  - /lookup skill: routes you to the right tool automatically`
        };
      }

      if (/target\/doc\//.test(cmd)) {
        return {
          result: `Blocked: grepping target/doc/ for symbol lookup. Use Context7 or LSP hover instead.
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

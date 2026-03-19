const INSTALL_PATTERNS = [
  { pattern: /\bnpm\s+install\b/, msg: 'npm install' },
  { pattern: /\byarn\s+add\b/, msg: 'yarn add' },
  { pattern: /\bpnpm\s+(add|install)\b/, msg: 'pnpm add/install' },
  { pattern: /\bpip3?\s+install\b/, msg: 'pip install' },
  { pattern: /\bgo\s+get\b/, msg: 'go get' },
  { pattern: /\bcargo\s+add\b/, msg: 'cargo add' },
];

const LEGACY_TOOLS = [
  { pattern: /^\s*(grep|egrep|fgrep)\b/, msg: 'Use the built-in Grep tool or /scout (rg). Example: Grep with pattern="..." path="..."' },
  { pattern: /^\s*sed\b/, msg: 'Use /chisel (sd) or the Edit tool. Example: sd \'pattern\' \'replacement\' file' },
  { pattern: /\bsed\s+-[^|]*i/, msg: 'Use /chisel (sd) or the Edit tool.' },
  { pattern: /^\s*awk\b/, msg: 'Use /chisel (sd) or the Edit tool.' },
  { pattern: /^\s*find\b/, msg: 'Use the Glob tool or /scout (fd). Example: Glob with pattern="**/*.ts"' },
];

const DEP_CACHES = [
  /\.cargo\/registry/, /node_modules\//, /\.pnpm-store/, /site-packages\//,
  /\.venv\/lib\//, /\/go\/pkg\/mod\//, /GOPATH.*pkg\/mod/,
  /\.m2\/repository\//, /\.gradle\/caches\//, /\.gem\//, /vendor\/bundle\//,
];

const DOC_GREP = [
  { gen: /cargo\s+doc\b/, label: 'cargo doc' },
  { gen: /go\s+doc\b/, label: 'go doc' },
  { gen: /pydoc3?\b/, label: 'pydoc' },
  { gen: /python3?\s+-c\s+.*help\s*\(/, label: 'python help()' },
  { gen: /ri\s+/, label: 'ri (Ruby)' },
];

const HEURISTIC_TRIGGERS = [
  { pattern: /\bcd\s+\S+\s*&&\s*git\b/, msg: 'Use /wt-git or git -C <path> instead. Example: wt-git /path/to/worktree commit -m "message"' },
  { pattern: /gh\s+pr\s+create\b[^|]*--body\s*"\$\(cat\b/, msg: 'Heredoc --body triggers "hides arguments" heuristic. Use MCP create_pull_request, or write body to $TMPDIR/pr-body.md and use gh pr create --body-file "$TMPDIR/pr-body.md".' },
  { pattern: /\bgh\s+[^|]+\|\s*jq\b/, msg: 'Use gh --jq instead of piping to jq. Example: gh pr list --json number,title --jq \'.[].title\'' },
  { pattern: /\bgh\s+[^|]+\|\s*(grep|head|tail|awk|sed|cut|sort|wc)\b/, msg: 'Use gh --jq for filtering/formatting. Example: gh pr list --json number --jq \'.[].number\'. Pipes trigger compound command detection.' },
];

function matchInstall(cmd) {
  const m = INSTALL_PATTERNS.find(r => r.pattern.test(cmd));
  if (!m) return null;
  return `Blocked: ${m.msg}. Package installation requires explicit approval.
Confirm why stdlib cannot solve this, review dependency weight, then approve explicitly.`;
}

function matchLegacyTool(cmd) {
  const m = LEGACY_TOOLS.find(r => r.pattern.test(cmd));
  if (!m) return null;
  return `Blocked: legacy tool via Bash. ${m.msg}`;
}

function matchFileWrite(cmd) {
  const clean = cmd
    .replace(/[12]?>+\s*\/dev\/(null|stderr|stdout)/g, '')
    .replace(/2>&1/g, '');
  if (/\$TMPDIR|\/private\/tmp\/claude|\/tmp\/claude/.test(cmd)) return null;
  if (/\bcat\s*>>?\s/.test(clean)) return 'Blocked: file creation via cat redirect. Use the Write tool.';
  if (/<<[-~]?\s*['"]?\w+/.test(clean) && />>?\s+\S/.test(clean)) return 'Blocked: file creation via heredoc redirect. Use the Write tool.';
  return null;
}

function matchInlineTest(cmd) {
  if (/python3?\s+-c\s+['"].*\bimport\b.*(?:\bassert\b|print\s*\()/.test(cmd)) return true;
  if (/python3?\s+-c\s+\$'/.test(cmd)) return true;
  if (/python3?\s+-c\s+['"][^'"]*\bimport\b[^'"]*;[^'"]*(?:\bassert\b|print\s*\()/.test(cmd)) return true;
  const norm = cmd.replace(/\n/g, ' ');
  if (/cat\s+<<[-~]?\s*['"]?\w+/.test(cmd) && /\bimport\b[\s\S]*(?:\bassert\b|print\s*\()/.test(norm)) return true;
  return false;
}

function matchBruteLookup(cmd) {
  for (const { gen, label } of DOC_GREP) {
    if (gen.test(cmd) && /grep|head|tail/.test(cmd))
      return `Blocked: ${label} + grep for symbol lookup. Use /lookup, /fetch (Context7), or LSP hover.`;
  }
  for (const pat of DEP_CACHES) {
    if (pat.test(cmd)) return `Blocked: grepping dependency cache (${cmd.match(pat)[0]}). Use /lookup, /fetch (Context7), or LSP hover.`;
  }
  if (/target\/doc\//.test(cmd) && /grep/.test(cmd)) return 'Blocked: grepping generated docs. Use /fetch (Context7) or LSP hover.';
  if (/find\s+.*-exec\s+grep/.test(cmd) || /find\s+.*\|\s*xargs\s+grep/.test(cmd))
    return 'Blocked: find + grep chain. Use /serena (find_symbol), /trace (ast-grep), or /lookup.';
  return null;
}

function matchHeuristic(cmd) {
  const m = HEURISTIC_TRIGGERS.find(r => r.pattern.test(cmd));
  if (!m) return null;
  return `Blocked: triggers Claude Code safety heuristic. ${m.msg}`;
}

const ALL_MATCHERS = [matchInstall, matchBruteLookup, matchLegacyTool, matchFileWrite, matchHeuristic];

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Bash') return false;
      const cmd = input.command || '';
      if (matchInlineTest(cmd)) return true;
      return ALL_MATCHERS.some(fn => fn(cmd));
    },
    handler: async (_toolName, input) => {
      const cmd = input.command || '';
      if (matchInlineTest(cmd)) {
        return { result: 'Blocked: python3 -c with test pattern. Use /test-sandbox or write a proper test file.' };
      }
      for (const fn of ALL_MATCHERS) {
        const msg = fn(cmd);
        if (msg) return { result: msg };
      }
      return { result: 'Use the dedicated tool instead of shell commands.' };
    }
  }]
};

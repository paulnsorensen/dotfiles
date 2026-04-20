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
  { pattern: /\bgh\s+api\b/, msg: 'Use /gh (GitHub MCP tools) instead of gh api. MCP bypasses sandbox TLS issues. For PR comments: pull_request_read(method: "get_review_comments"), for issues: issue_read.' },
  { pattern: /\bgit\s+add\b[^|]*&&\s*git\s+commit\b/, msg: 'Use /commit instead. Compound git add && git commit with heredoc triggers "hides arguments" heuristic and requires sandbox bypass.' },
  { pattern: /\bgit\s+commit\b.*\$\(/, msg: 'Use /commit instead. Command substitution in git commit triggers "backticks" or "hides arguments" heuristic. The /commit skill handles staging, message drafting, and committing.' },
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

const PYTHON_AS_TOOL = [
  {
    pattern: /\|\s*python3?\s+.*\bjson[.\s]*(load|loads|dump|dumps)\b/,
    msg: 'Blocked: piping to python3 for JSON processing. Use jq instead. Example: gh api ... | jq \'.field\' or cat file.json | jq \'.key\'. For gh: use gh --jq. For JSONL: use jq -c on each line.',
  },
  {
    pattern: /python3?\s+(-c\s+['"$]|<<).*\bjson[.\s]*(load|loads)\b.*\bopen\s*\(/s,
    msg: 'Blocked: python3 for reading+parsing JSON files. Use jq: jq \'.\' file.json. For field extraction: jq \'.field\' file.json. For JSONL: jq -c \'.\' file.jsonl.',
  },
  {
    pattern: /python3?\s+(-c\s+['"$]|<<).*\bjson[.\s]*(dump|dumps)\b.*\bopen\s*\(.*['"]\s*w/s,
    msg: 'Blocked: python3 for writing JSON files. Use the Write tool with JSON content, or jq for transforms: jq \'.key = "value"\' file.json > tmp && mv tmp file.json.',
  },
  {
    pattern: /python3?\s+-m\s+json\.tool\b/,
    msg: 'Blocked: python3 -m json.tool for pretty-printing. Use jq: echo \'{"a":1}\' | jq \'.\' or jq \'.\' file.json.',
  },
  {
    pattern: /python3?\s+(-c\s+['"$]|<<).*\bimport\s+re\b.*\b(re\.sub|re\.match|re\.search|re\.findall)\b/s,
    msg: 'Blocked: python3 for regex file manipulation. Use sd (chisel skill) for replacements: sd \'pattern\' \'replacement\' file. Or use the Edit tool for precise edits.',
  },
  {
    pattern: /python3?\s+(-c\s+['"$]|<<).*\bimport\s+yaml\b/s,
    msg: 'Blocked: python3 for YAML processing. Use yq instead. Example: yq \'.\' file.yml (validate), yq \'.key\' file.yml (extract), yq -i \'.key = "val"\' file.yml (edit in-place).',
  },
];

function matchPythonAsTool(cmd) {
  // Skip scripts in /tmp (legitimate scratch work) and skill/hook scripts
  if (/python3?\s+\//.test(cmd) && !/python3?\s+-[cm]/.test(cmd)) return null;
  if (/\$TMPDIR|\/private\/tmp\/claude|\/tmp\/claude/.test(cmd)) return null;

  const norm = cmd.replace(/\n/g, ' ');
  const m = PYTHON_AS_TOOL.find(r => r.pattern.test(norm));
  if (!m) return null;
  return m.msg;
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
    return 'Blocked: find + grep chain. Use LSP (findReferences), /trace (ast-grep), or /lookup.';
  return null;
}

function matchHeuristic(cmd) {
  const m = HEURISTIC_TRIGGERS.find(r => r.pattern.test(cmd));
  if (!m) return null;
  return `Blocked: triggers Claude Code safety heuristic. ${m.msg}`;
}

const ALL_MATCHERS = [matchInstall, matchBruteLookup, matchLegacyTool, matchFileWrite, matchPythonAsTool, matchHeuristic];

module.exports = {
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

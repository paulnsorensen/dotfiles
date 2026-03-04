// block-file-write.js
// Blocks shell-based file creation (cat >, heredoc) — agents should use the Write tool
// Part of the Cheddar Flow enforcement system

module.exports = {
  event: 'preToolUse',
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Bash') return false;
      const cmd = input.command || '';
      // Strip /dev/null redirects and stderr merges — those are output suppression, not file creation
      const clean = cmd
        .replace(/[12]?>+\s*\/dev\/(null|stderr|stdout)/g, '')
        .replace(/2>&1/g, '');
      // Allow writes to $TMPDIR — temp report files from pipeline agents
      if (/\$TMPDIR|\/private\/tmp\/claude|\/tmp\/claude/.test(cmd)) return false;
      // 1. cat > file or cat >> file (stdin-to-file creation)
      if (/\bcat\s*>>?\s/.test(clean)) return true;
      // 2. heredoc combined with file redirect (inline file content to disk)
      if (/<<[-~]?\s*['"]?\w+/.test(clean) && />>?\s+\S/.test(clean)) return true;
      return false;
    },
    handler: async () => ({
      result: `Blocked: file creation via cat/heredoc redirect.

Use the Write tool to create files — it's auditable and reviewable.
Agents without Write access (like whey-drainer) are read-only by design.
If you need to create or modify test files, delegate to roquefort-wrecker.`
    })
  }]
};

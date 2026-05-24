// bash-guard.js
// Blocks dangerous `rm -rf` invocations: recursive + force removals that target
// the filesystem root, the home directory, parent-traversal (..) paths,
// absolute system directories, or a bare glob. Relative subdirectory removals
// (node_modules, dist, build, .cheese/foo) are allowed.

function stripQuotes(s) {
  return s.replace(/^['"]/, '').replace(/['"]$/, '');
}

function isHomeRooted(t) {
  // Any tilde- or $HOME-rooted target. These are absolute home paths, not the
  // relative subdir deletes (node_modules, dist) we allow.
  if (t === '~' || t.startsWith('~/')) return true;
  if (/\$\{?HOME\}?(\/|$)/.test(t)) return true; // $HOME, ${HOME}, $HOME/..., ${HOME}/...
  const home = process.env.HOME || '';
  if (home && (t === home || t === home + '/')) return true;
  return false;
}

function isDangerousTarget(rawTarget) {
  const t = stripQuotes(rawTarget.trim());
  if (!t) return false;
  // Scratch roots are safe even though they sit under system paths. /tmp and
  // the macOS per-user temp (/var/folders/...) are reachable both directly and
  // via the /private firmlink, so allow both forms BEFORE the system-dir rule.
  if (/^(\/private)?\/tmp(\/|$)/.test(t)) return false;
  if (/^(\/private)?\/var\/folders(\/|$)/.test(t)) return false;
  if (t === '/' || t === '/*' || t === '/.') return true;
  if (isHomeRooted(t)) return true;
  // Absolute OS system dirs — dangerous at any depth (also via /private/...).
  if (/^(\/private)?\/(bin|sbin|usr|etc|var|lib|lib64|opt|System|Library|dev|boot|proc|sys|root)(\/|$)/.test(t)) return true;
  if (/^\/private(\/|$)/.test(t)) return true;
  // User-data roots — dangerous only when shallow (the root or a single user dir).
  if (/^\/(Users|home)(\/[^/]+)?\/?$/.test(t)) return true;
  // Current dir / parent traversal.
  if (t === '.' || t === './' || t === '..' || t === '../') return true;
  if (/(^|\/)\.\.(\/|$)/.test(t)) return true;
  // Bare glob expanding in cwd.
  if (t === '*' || t === './*' || t === '*/') return true;
  return false;
}

// Split a shell line into command segments at separators.
function splitSegments(command) {
  return command.split(/(?:&&|\|\||[;&|\n()])+/);
}

function dangerousRm(command) {
  for (const seg of splitSegments(command)) {
    const tokens = seg.trim().split(/\s+/).filter(Boolean);
    let i = 0;
    while (i < tokens.length && (tokens[i] === 'sudo' || /(^|\/)env$/.test(tokens[i]))) i++;
    if (i >= tokens.length || !/(^|\/)rm$/.test(tokens[i])) continue;
    const args = tokens.slice(i + 1);
    let recursive = false;
    let force = false;
    let optsEnded = false;
    const targets = [];
    for (const a of args) {
      if (!optsEnded && a === '--') { optsEnded = true; continue; }
      if (!optsEnded && a.startsWith('--')) {
        if (a === '--recursive') recursive = true;
        if (a === '--force') force = true;
        continue;
      }
      if (!optsEnded && a.length > 1 && a.startsWith('-')) {
        if (/[rR]/.test(a)) recursive = true;
        if (/f/.test(a)) force = true;
        continue;
      }
      targets.push(a);
    }
    if (recursive && force && targets.some(isDangerousTarget)) return true;
  }
  return false;
}

module.exports = {
  hooks: [{
    matcher: (toolName, input) => toolName === 'Bash' && dangerousRm((input && input.command) || ''),
    handler: async (_toolName, input) => ({
      result: `Blocked: dangerous \`rm -rf\` detected in:
  ${((input && input.command) || '').trim()}

This recursive force-delete targets the filesystem root, your home directory, a
parent-traversal (..) path, an absolute system directory, or a bare glob.
Relative subdirectory deletes (e.g. \`rm -rf node_modules\`) are allowed.

If this is intentional, run it yourself outside the agent, or scope the target
to a specific relative path.`,
    }),
  }],
};

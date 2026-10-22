// Pure gate helpers for cheese-factory.js. This file is a plain script: no import and no export.
// sync.mjs pastes it into the shared gates block of cheese-factory.js. Edit it here, then run sync.mjs.
// The helpers read no workflow global. normalizeFile needs SCRATCH_PATH_SRC from prelude.js.

// A range is path#start-end with start <= end, so a one-line #n-n range is valid.
const validGroundedRange = (range) => {
  if (typeof range !== 'string' || range.length > 200 || range !== range.trim()) return false
  const match = /^(?!\/)(?![A-Za-z]:[\\/])(?!.*(?:^|\/)\.\.(?:\/|$))(?!.*(?:^|\/)\.(?:\/|$))[^#\s][^#\n\r]*#([1-9]\d*)-([1-9]\d*)$/.exec(range)
  return Boolean(match) && Number(match[1]) <= Number(match[2])
}
// Keeps the valid ranges and drops the rest. An empty list is allowed.
const groundedRanges = (ranges) => (Array.isArray(ranges) ? ranges.filter(validGroundedRange).slice(0, 16) : [])

function mergeCoupledCurds(curds) {
  const groups = curds.map((c) => ({ slugs: [c.slug], briefs: [c.brief], files: new Set(c.files || []), deps: new Set(c.depends_on || []) }))
  const coupled = (a, b) =>
    [...a.files].some((f) => b.files.has(f)) ||
    a.slugs.some((s) => b.deps.has(s)) ||
    b.slugs.some((s) => a.deps.has(s))
  let changed = true
  while (changed) {
    changed = false
    findPair:
    for (let i = 0; i < groups.length; i++) {
      for (let j = i + 1; j < groups.length; j++) {
        if (coupled(groups[i], groups[j])) {
          groups[i].slugs.push(...groups[j].slugs)
          groups[i].briefs.push(...groups[j].briefs)
          for (const f of groups[j].files) groups[i].files.add(f)
          for (const d of groups[j].deps) groups[i].deps.add(d)
          groups.splice(j, 1)
          changed = true
          break findPair
        }
      }
    }
  }
  return groups.map((g) => ({
    slug: g.slugs[0],
    brief: g.briefs.join('\n\n'),
    files: [...g.files],
    merged_from: g.slugs.length > 1 ? g.slugs : undefined,
  }))
}

// ---- routing: code assigns findings to curds by the files each curd changed ----
const isMediumPlus = (f) => f.severity !== 'low'
const needsCure = (f) => isMediumPlus(f) || f.fix_cost_now === 'contained'
// A finding owned by two curds routes to the first owner in slug order. Each other owner lands in shared, keyed to the owners that cure it.
// unrouted is true when a finding that needs cure has no owner (an unowned low that needs no cure stays out),
// or when the result claims medium+ findings or contained lows that its list does not carry.
// A finding file may carry a leading ./ or a worktree prefix; both name the same repo path.
// The prefix is the producer's own worktree_path, or any scratch worktree root.
const SCRATCH_PREFIX_RE = new RegExp(`^${SCRATCH_PATH_SRC}\\/`)
const normalizeFile = (file, worktreePath) => {
  let p = String(file).trim()
  const root = worktreePath ? String(worktreePath).replace(/\/+$/, '') + '/' : null
  p = root && p.startsWith(root) ? p.slice(root.length) : p.replace(SCRATCH_PREFIX_RE, '')
  return p.replace(/^(\.\/)+/, '')
}
function routeFindings(result, filesBySlug, slugs, worktreePath) {
  const bySlug = new Map()
  const shared = new Map()
  const sharedFindings = new Map()
  // unownedMedium marks a medium+ finding that no curd owns. unrouted also fires for an unowned contained low.
  let unownedMedium = Boolean(result.has_medium_plus_findings) && !result.findings.some(isMediumPlus)
  let unrouted = unownedMedium ||
    (Boolean(result.has_cheap_lows) && !result.findings.some((f) => f.severity === 'low' && f.fix_cost_now === 'contained'))
  for (const f of result.findings.filter(needsCure)) {
    const file = normalizeFile(f.file, worktreePath)
    const owners = slugs.filter((s) => (filesBySlug[s] || []).includes(file))
    if (!owners.length) {
      unrouted = true
      if (isMediumPlus(f)) unownedMedium = true
      continue
    }
    const [first, ...others] = owners
    bySlug.set(first, [...(bySlug.get(first) || []), { ...f, file }])
    for (const s of others) {
      shared.set(s, new Set([...(shared.get(s) || []), first]))
      sharedFindings.set(s, [...(sharedFindings.get(s) || []), { ...f, file }])
    }
  }
  return { bySlug, shared, sharedFindings, unrouted, unownedMedium }
}

// A judge runs each criterion check, so a check must not fetch, write, or mutate.
// Three layers run in order: a structural pre-filter on the raw text, this denylist, and per-command rules.
// The layers are defense in depth; the judge agent definition is the other guard.
// The third field marks a rule that reads the text with quoted spans masked.
const UNSAFE_CHECKS = [
  ['network access', /\b(?:curl|wget|nc|ssh|scp)\b/i],
  ['pipe into a shell', /\|\s*(?:sh|bash|zsh)\b/i],
  // Only fd duplication (>&1, 2>&1, >&-) and a redirect to the whole token /dev/null stay allowed.
  ['output redirection to a file', />(?!>?\s*\/dev\/null(?![^\s;|&)])|&(?:\d+|-)(?![^\s;|&)]))/, true],
  ['tree mutation', /(?:^|[;&|(]\s*|\b(?:sudo|xargs|env|command|time)\s+)(?:touch|mkdir|rmdir|cp|mv|chmod|chown|chgrp|ln|install|truncate|dd|patch)\s/i],
  ['tee to a file', /\btee\b/i],
  ['inline interpreter code', /\b(?:python3?|node|perl|ruby)\s+-[ce]\b/i],
  ['in-place edit', /\bsed\s+(?:-[a-zA-Z]*i|--in-place)|\bperl\s+-[a-zA-Z]*i/i],
  ['file removal', /\brm\s|\s-delete\b|\bunlink\b|\btruncate\b/i],
  ['package publish or install', /\b(?:npm|pnpm|yarn|cargo|pip3?|uv)\s+(?:publish|install|add|ci)\b/i],
  ['GitHub mutation', /\bgh\s+(?:pr\s+(?:merge|close|comment|edit|ready|review|create|reopen)|issue|release|workflow\s+run|run\s+(?:rerun|cancel)|repo\s+(?:edit|delete|rename)|secret|variable|label)\b/i],
  ['GitHub API write', /\bgh\s+api\b.*(?:-X|--method)[\s=]*(?:POST|PATCH|PUT|DELETE)\b/i],
  ['GitHub API field write', /\bgh\s+api\b.*\s(?:-f|-F|--field|--raw-field|--input)[\s=]/i],
]

const hit = (name, text = '') => ({ name, text })

// Replaces each quoted span and each backslash escape with Q, so an operator inside a quote is data.
// Double quotes stay readable unless maskDouble is true, because $ and backticks expand inside them.
function maskQuotes(check, maskDouble) {
  let out = ''
  for (let i = 0; i < check.length; i++) {
    const c = check[i]
    if (c === '\\') { out += 'Q'; i++ } else if (c === "'") {
      const close = check.indexOf("'", i + 1)
      if (close < 0) return out + check.slice(i)
      out += 'Q'
      i = close
    } else if (c === '"') {
      let j = i + 1
      let inner = ''
      for (; j < check.length && check[j] !== '"'; j++) inner += check[j] === '\\' ? (j++, 'Q') : check[j]
      if (j >= check.length) return out + check.slice(i)
      out += maskDouble ? 'Q' : `"${inner}"`
      i = j
    } else out += c
  }
  return out
}

// Shapes that hide a command from the lexical rules: raw newlines, here documents, and shell expansion.
function structuralHit(check) {
  if (/[\r\n]/.test(check)) return hit('raw newline or carriage return')
  const heredoc = /<<-?/.exec(maskQuotes(check, true))
  if (heredoc) return hit('here document', heredoc[0])
  const readable = maskQuotes(check, false)
  const expansion = /\$(?:[({A-Za-z_]|\d|[?!@*#$-])|`/.exec(readable)
  if (expansion) return hit('shell expansion or substitution', readable.slice(expansion.index, expansion.index + 24).trim())
  return null
}

const ASSIGN_RE = /^[A-Za-z_]\w*=/
const WRAPPERS = new Set(['env', 'command', 'time', 'sudo', 'doas', 'xargs', 'nohup', 'nice', 'timeout', 'builtin', 'stdbuf', 'setsid', 'ionice'])
const WRAPPER_VALUE_OPTS = { xargs: ['-I', '-L', '-n', '-P', '-s', '-E', '-d', '-a'], env: ['-u', '-C', '-S'], sudo: ['-u', '-g', '-C', '-h', '-p', '-r', '-t', '-U'], timeout: ['-s', '-k'], nice: ['-n'] }
const SHELL_KEYWORDS = new Set(['{', '}', 'if', 'then', 'else', 'elif', 'fi', 'do', 'done', 'while', 'until', 'for', 'case', 'esac', 'function', 'select', 'coproc'])
const MUTATION_COMMANDS = new Set(['touch', 'mkdir', 'rmdir', 'cp', 'mv', 'chmod', 'chown', 'chgrp', 'ln', 'install', 'truncate', 'dd', 'patch', 'rm', 'unlink', 'shred', 'mkfifo', 'mknod'])
const NETWORK_COMMANDS = new Set(['curl', 'wget', 'nc', 'ncat', 'netcat', 'telnet', 'ftp', 'sftp', 'ssh', 'scp', 'rsync', 'socat'])
const FETCH_RUNNERS = new Set(['npx', 'pnpx', 'bunx', 'uvx', 'pipx'])
const PACKAGE_MANAGERS = new Set(['npm', 'pnpm', 'yarn', 'bun', 'pip', 'pip3', 'cargo', 'uv', 'gem'])
const INSTALL_SUBCOMMANDS = new Set(['install', 'i', 'ci', 'add', 'exec', 'x', 'dlx', 'create', 'init', 'update', 'upgrade', 'publish', 'remove', 'uninstall', 'link'])
const SHELL_HEAD_RE = /^(?:sh|bash|zsh|dash|ksh|fish|csh|tcsh)$/
const CODE_HEAD_RE = /^(?:python|ruby|perl|php|lua|node|nodejs|deno|bun|osascript)[\d.]*$/
const AWK_HEAD_RE = /^[gmn]?awk$/
const AWK_DANGER_RE = /\bsystem\s*\(|\bgetline\b|\bprintf?\b[^}]*[>|]|-i\s*inplace|@(?:include|load)|\|&/
const SED_WRITE_RE = /(?:^|[;{}])\s*(?:\d+|\$|\/[^/]*\/)?\s*(?:w\s*\S|e\b)|s\/[^/]*\/[^/]*\/[a-zA-Z0-9]*[we]\b/
const GIT_VALUE_OPTS = new Set(['-C', '--git-dir', '--work-tree', '--namespace', '--super-prefix', '--exec-path'])
const GIT_MUTATIONS = new Set(['push', 'add', 'commit', 'reset', 'checkout', 'switch', 'merge', 'rebase', 'stash', 'clean', 'tag', 'am', 'apply', 'restore', 'rm', 'mv', 'init', 'cherry-pick', 'revert', 'pull', 'worktree', 'update-ref', 'config', 'fetch', 'clone', 'ls-remote', 'submodule', 'gc', 'prune', 'maintenance', 'notes', 'replace', 'filter-branch', 'bisect', 'sparse-checkout', 'format-patch', 'checkout-index', 'read-tree', 'write-tree', 'commit-tree', 'fast-import', 'unpack-objects', 'bundle', 'archive', 'send-email', 'difftool', 'mergetool'])

// Skips wrapper commands and their options so the real command head shows.
function unwrap(words) {
  let i = 0
  while (WRAPPERS.has(words[i])) {
    const valued = WRAPPER_VALUE_OPTS[words[i++]] ?? []
    while (i < words.length && (words[i].startsWith('-') || ASSIGN_RE.test(words[i]) || /^\d+(?:\.\d+)?[smhd]?$/.test(words[i]))) i += valued.includes(words[i]) ? 2 : 1
  }
  return words.slice(i)
}

// Reads the git subcommand from tokens, so the cost stays linear in the option count.
function gitHit(args) {
  let i = 0
  for (; i < args.length && args[i].startsWith('-'); i++) {
    const arg = args[i]
    if ((arg.startsWith('-c') && !arg.startsWith('--')) || arg.startsWith('--config-env')) return hit('git config override', arg)
    if (GIT_VALUE_OPTS.has(arg)) i++
  }
  const sub = (args[i] ?? '').toLowerCase()
  const rest = args.slice(i + 1)
  if (GIT_MUTATIONS.has(sub)) return hit('git mutation', `git ${sub}`)
  if (sub === 'branch' && rest.some((a) => /^-[a-zA-Z]*[dDmMfcC]|^--(?:delete|move|copy|force|set-upstream|unset-upstream|edit-description)/.test(a))) return hit('git mutation', 'git branch')
  const output = rest.find((a) => /^--output(?:=|$)/.test(a) || (sub === 'grep' && /^(?:-O|--open-files-in-pager)/.test(a)))
  return output ? hit('git option that writes a file or runs a program', output) : null
}

function sedHit(args) {
  const programs = []
  let bare = true
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (/^-[a-zA-Z]*[if]|^--(?:in-place|file)/.test(arg)) return hit('in-place edit or script file', arg)
    if (arg === '-e' || arg === '--expression') { programs.push(args[++i] ?? ''); bare = false } else if (arg.startsWith('--expression=')) { programs.push(arg.slice(13)); bare = false } else if (bare && !arg.startsWith('-')) { programs.push(arg); bare = false }
  }
  const bad = programs.find((p) => SED_WRITE_RE.test(p))
  return bad === undefined ? null : hit('sed command that writes or runs', bad)
}

const COMMAND_OPS = ['&&', '||', ';', '&']
const unparen = (words) => words.map((w) => w.replace(/^\(+|\)+$/g, '')).filter(Boolean)

// Splits a check into words and the operators && || ; | &, with POSIX quotes removed. A newline counts as ;. Returns null on an open quote.
function shellWords(check) {
  const words = []
  let word = null
  const end = () => { if (word !== null) words.push(word); word = null }
  for (let i = 0; i < check.length; i++) {
    const c = check[i]
    const pair = check.slice(i, i + 2)
    if (c === '\n') { end(); words.push(';') }
    else if (/\s/.test(c)) end()
    else if (pair === '&&' || pair === '||') { end(); words.push(pair); i++ }
    else if (pair === '|&') { end(); words.push('|'); i++ }
    else if (c === '&' && check[i - 1] !== '>' && check[i - 1] !== '<' && check[i + 1] !== '>') { end(); words.push('&') }
    else if (c === ';' || c === '|') { end(); words.push(c) }
    else if (c === "'") {
      const close = check.indexOf("'", i + 1)
      if (close < 0) return null
      word = (word ?? '') + check.slice(i + 1, close)
      i = close
    } else if (c === '"') {
      let j = i + 1
      let text = ''
      for (; j < check.length && check[j] !== '"'; j++) text += check[j] === '\\' && j + 1 < check.length ? check[++j] : check[j]
      if (j >= check.length) return null
      word = (word ?? '') + text
      i = j
    } else if (c === '\\' && i + 1 < check.length) word = (word ?? '') + check[++i]
    else word = (word ?? '') + c
  }
  end()
  return words
}

// Classifies one simple command. Returns a hit or null.
function commandHit(raw) {
  const words = unparen(raw)
  while (words[0] === '!') words.shift()
  if (!words.length) return null
  if (ASSIGN_RE.test(words[0])) return hit('NAME=value prefix', words[0])
  const [head, ...args] = unwrap(words)
  if (head === undefined) return null
  if (head.includes('/')) return hit('command path', head)
  if (['eval', 'exec', 'source', '.'].includes(head)) return hit('eval, exec, or source', head)
  if (SHELL_KEYWORDS.has(head)) return hit('shell keyword or group', head)
  if (MUTATION_COMMANDS.has(head)) return hit('tree mutation', head)
  if (NETWORK_COMMANDS.has(head)) return hit('network access', head)
  if (FETCH_RUNNERS.has(head)) return hit('package fetch or execution', head)
  if (PACKAGE_MANAGERS.has(head) && INSTALL_SUBCOMMANDS.has(args[0])) return hit('package install or execution', `${head} ${args[0]}`)
  if (head === 'git') return gitHit(args)
  if (head === 'find') {
    const action = args.find((a) => /^-(?:exec|execdir|ok|okdir|delete|fprint0?|fprintf|fls)$/.test(a))
    return action ? hit('find action that writes or runs a command', action) : null
  }
  if (head === 'sed') return sedHit(args)
  if (AWK_HEAD_RE.test(head)) {
    const bad = args.find((a) => AWK_DANGER_RE.test(a) || /^(?:-f|--file|-i|--include|-l|--load)/.test(a))
    return bad === undefined ? null : hit('awk program that writes or runs a command', bad)
  }
  if (SHELL_HEAD_RE.test(head) && (!args.length || args.some((a) => a === '-' || /^-[a-zA-Z]*[cs]/.test(a)))) return hit('inline interpreter code', `${head} ${args[0] ?? ''}`.trim())
  if (CODE_HEAD_RE.test(head)) {
    const code = !args.length || args.some((a) => a === '-' || /^-[a-zA-Z]*[cepE]/.test(a) || /^--(?:eval|print|exec|command)\b/.test(a)) || (head === 'deno' && ['eval', 'repl'].includes(args[0]))
    if (code) return hit('inline interpreter code', `${head} ${args[0] ?? ''}`.trim())
  }
  return null
}

// Returns { name, text } for the first unsafe shape in a check, or null.
function unsafeCheck(check) {
  const structural = structuralHit(check)
  if (structural) return structural
  const masked = maskQuotes(check, true)
  for (const [name, re, useMask] of UNSAFE_CHECKS) {
    const subject = useMask ? masked : check
    const m = re.exec(subject)
    if (m) return hit(name, subject.slice(m.index, m.index + 24).trim())
  }
  const words = shellWords(check)
  if (!words) return null
  let command = []
  for (const w of [...words, ';']) {
    if (COMMAND_OPS.includes(w) || w === '|') {
      const found = commandHit(command)
      if (found) return found
      command = []
    } else command.push(w)
  }
  return null
}

// module: guard; provides: UNSAFE_CHECKS, GUARD_PREFERRED, unsafeCheck, guardedReaderReason, vacuousReason, shellWords; requires: none
// The check-safety guard for criterion checks. It holds the stricter cheese-factory rules.
// Public: unsafeCheck, vacuousReason, guardedReaderReason. Tests also use shellWords, UNSAFE_CHECKS, and GUARD_PREFERRED.
// Every other top-level name is a private helper of this module.

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

// These commands take a pattern or text as data, so a quoted "git push" operand is not a command.
const DATA_HEADS = new Set(['echo', 'printf', 'test', '[', '[[', 'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'awk', 'gawk', 'mawk', 'sed', 'gsed', 'find'])

// Finds git at any word position after an unlisted wrapper (watch, gtimeout, su -c, strace).
// A word that holds spaces, such as "git push" after su -c, splits into its own tokens.
function embeddedGit(args) {
  for (let i = 0; i < args.length; i++) {
    const tokens = args[i].split(/\s+/).filter(Boolean)
    if (tokens[0]?.toLowerCase() !== 'git') continue
    const found = gitHit([...tokens.slice(1), ...args.slice(i + 1)])
    if (found) return found
  }
  return null
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
  // A case-insensitive file system runs GIT as git, so the head match ignores case.
  if (head.toLowerCase() === 'git') return gitHit(args)
  if (!DATA_HEADS.has(head)) {
    const embedded = embeddedGit(args)
    if (embedded) return embedded
  }
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

// The user's PreToolUse hook (agents/lib/tool-reroute) denies a shell reader or searcher that reads a file.
// A check that names a file operand never runs, so the judge cannot give a verdict. This gate mirrors the hook.
// A filter on a pipe (git log | grep x) reads no file and stays allowed.
const GUARD_PREFERRED = "run the repository's own test for the criterion (node --test --test-name-pattern, pytest -k, bats -f, a just recipe), or use test -e or git plumbing"
const GUARD_READERS = {
  cat: '', tac: 's', head: 'nc', tail: 'ncs', less: 'bhjkoOpPtTxyz#', more: 'n', nl: 'bdfhilnsvw', bat: 'lHmr', batcat: 'lHmr',
  sed: 'efl', gsed: 'efl', awk: 'Fvfei', gawk: 'Fvfei', mawk: 'Fvfei',
  grep: 'efmABCdD', egrep: 'efmABCdD', fgrep: 'efmABCdD', rg: 'efgtTmABCjMrdE', ag: 'ABCGgm', ack: 'ABCm',
}
// The first operand of these is a pattern or program, unless -e or -f supplies it.
const GUARD_SCRIPTED = new Set(['sed', 'gsed', 'awk', 'gawk', 'mawk', 'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack'])
const GUARD_VALUED_LONG = ['regexp', 'file', 'expression', 'max-count', 'context', 'after-context', 'before-context', 'include', 'exclude', 'exclude-dir', 'glob', 'iglob', 'type', 'type-not', 'max-depth', 'lines', 'bytes', 'line-range', 'style', 'language', 'theme']
const GUARD_WRAPPERS = new Set(['xargs', 'time', 'command', 'env', 'sudo', 'nice', 'nohup'])
const GUARD_LISTING = ['--files', '--type-list', '--list-file-types', '--help-types']

// The files that one reader or searcher stage reads. first is true when no pipe feeds the stage.
function guardedFiles(head, args, first) {
  const valued = GUARD_READERS[head]
  if (valued === undefined) return []
  if (args.some((a) => GUARD_LISTING.includes(a)) || ((head === 'ag' || head === 'ack') && args.includes('-g')) || (head === 'ack' && args.includes('-f'))) return []
  const operands = []
  let scripted = false
  let options = true
  let recursive = head === 'rg' || head === 'ag' || head === 'ack'
  for (let i = 0; i < args.length; i++) {
    const a = args[i]
    if (/^\d*<<<$/.test(a) || /^\d*<<-?$/.test(a)) i++
    else if (/^\d*<</.test(a)) continue
    else if (/^\d*<$/.test(a)) { if (args[i + 1] !== undefined) operands.push(args[++i]) }
    else if (/^\d*<./.test(a)) operands.push(a.replace(/^\d*</, ''))
    else if (/^(?:\d*|&)>/.test(a)) { if (/^(?:\d*|&)>>?&?$/.test(a)) i++ }
    else if (options && a === '--') options = false
    else if (options && a.startsWith('--')) {
      const [name, value] = a.slice(2).split('=')
      if (['regexp', 'file', 'expression'].includes(name)) scripted = true
      if (name === 'recursive' || name === 'dereference-recursive') recursive = true
      if (value === undefined && GUARD_VALUED_LONG.includes(name)) i++
    } else if (options && a.length > 1 && a.startsWith('-')) {
      const letters = a.slice(1)
      for (let k = 0; k < letters.length; k++) {
        if (/grep$/.test(head) && 'rR'.includes(letters[k])) recursive = true
        if (!valued.includes(letters[k])) continue
        if ('ef'.includes(letters[k])) scripted = true
        if (k === letters.length - 1) i++
        break
      }
    } else if (a !== '-' && !a.startsWith('+')) operands.push(a)
  }
  if (GUARD_SCRIPTED.has(head) && !scripted) operands.shift()
  if (!operands.length && first && recursive) return ['.']
  return operands
}

// Returns why a check cannot run under the PreToolUse guard, or '' when it can.
function guardedReaderReason(check) {
  const words = shellWords(check)
  if (!words) return ''
  let stage = []
  let first = true
  for (const w of [...words, ';']) {
    if (!COMMAND_OPS.includes(w) && w !== '|') { stage.push(w); continue }
    const command = stage.map((s) => s.replace(/^\(+|\)+$/g, '')).filter(Boolean)
    let wrapped = false
    while (command.length && (command[0] === '!' || ASSIGN_RE.test(command[0]) || GUARD_WRAPPERS.has(command[0]) || (wrapped && command[0].startsWith('-')))) {
      wrapped = wrapped || GUARD_WRAPPERS.has(command[0])
      command.shift()
    }
    const files = command.length ? guardedFiles(command[0], command.slice(1), first) : []
    if (files.length) return `\`${command[0]}\` reads ${files.join(', ')}, which the repository's PreToolUse guard denies, so the check never runs. Instead ${GUARD_PREFERRED}`
    first = w !== '|'
    stage = []
  }
  return ''
}

// A negated search passes when its input is missing. Grep and rg exit 2 on a missing file.
// Git grep exits 1 on an unmatched pathspec. Grep with no file reads empty input.
// So each path of a negated search needs an existence test earlier in the same && chain.
// A negated pipeline also hides a failed producer. This check is lexical.
// The verify judge also tests each path that a check reads.
const SEARCH_TOOLS = ['grep', 'egrep', 'fgrep', 'rg']
// Short options whose value is the next word when the option ends its cluster.
const VALUE_LETTERS = { rg: 'efgtTmABCjMEr', grep: 'efmABCdD' }
const LONG_VALUE_OPTS = ['regexp', 'file', 'max-count', 'after-context', 'before-context', 'context', 'include', 'exclude', 'exclude-dir', 'glob', 'iglob', 'type', 'type-not', 'max-depth']

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

// A redirect such as 2>/dev/null, >&2, or &> is not an operand; a bare operator such as > takes the next word.
const REDIRECT_RE = /^(?:\d*|&)[<>]/
const BARE_REDIRECT_RE = /^(?:\d*|&)(?:[<>]|>>)&?$/
// ./a and a name the same path.
const samePath = (path) => path.replace(/^(?:\.\/)+/, '')

// test -e P, [ -e P ], or [[ -e P ]] with -e, -f, -d, -s, or -r; returns P or ''.
function guardedPath(words) {
  const flag = /^-[efdsr]$/
  if (words.length === 3 && words[0] === 'test' && flag.test(words[1])) return samePath(words[2])
  if (words.length === 4 && flag.test(words[1]) && ((words[0] === '[' && words[3] === ']') || (words[0] === '[[' && words[3] === ']]'))) return samePath(words[2])
  return ''
}

// Returns { tool, paths, stdin } for a grep, rg, or git grep command, or null for any other command.
function searchOf(words) {
  const git = words[0] === 'git' && words[1] === 'grep'
  if (!git && !SEARCH_TOOLS.includes(words[0])) return null
  const tool = git ? 'git grep' : words[0]
  const args = words.slice(git ? 2 : 1)
  const valueLetters = tool === 'rg' ? VALUE_LETTERS.rg : VALUE_LETTERS.grep
  const positional = []
  let patternGiven = false
  let recursive = false
  let options = true
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (REDIRECT_RE.test(arg)) {
      if (BARE_REDIRECT_RE.test(arg)) i++
    } else if (options && arg === '--') options = false
    else if (options && arg.startsWith('--')) {
      const [name, value] = arg.slice(2).split('=')
      if (name === 'regexp' || name === 'file') patternGiven = true
      if (name === 'recursive' || name === 'dereference-recursive') recursive = true
      if (value === undefined && LONG_VALUE_OPTS.includes(name)) i++
    } else if (options && arg.length > 1 && arg.startsWith('-')) {
      const letters = arg.slice(1)
      for (let k = 0; k < letters.length; k++) {
        if (tool !== 'rg' && 'rR'.includes(letters[k])) recursive = true
        if (!valueLetters.includes(letters[k])) continue
        if ('ef'.includes(letters[k])) patternGiven = true
        if (k === letters.length - 1) i++
        break
      }
    } else positional.push(arg)
  }
  const paths = (patternGiven ? positional : positional.slice(1)).map(samePath)
  return { tool, paths, stdin: tool !== 'rg' && tool !== 'git grep' && !paths.length && !recursive }
}

const COMMAND_OPS = ['&&', '||', ';', '&']
// A pipe sink reads its input, so it cannot fail on a failed producer.
const PIPE_SINKS = new Set(['wc', 'head', 'tail', 'cat'])
const unparen = (words) => words.map((w) => w.replace(/^\(+|\)+$/g, '')).filter(Boolean)

function withoutRedirects(words) {
  const kept = []
  for (let i = 0; i < words.length; i++) {
    if (!REDIRECT_RE.test(words[i])) kept.push(words[i])
    else if (BARE_REDIRECT_RE.test(words[i])) i++
  }
  return kept
}

function pipelineStages(words) {
  const stages = [[]]
  for (const w of words) {
    if (w === '|') stages.push([])
    else stages[stages.length - 1].push(w)
  }
  return stages.filter((s) => s.length)
}

const exitsZero = (stage) => stage[0] === 'exit' && (stage.length === 1 || (stage.length === 2 && stage[1] === '0'))

// True when a pipeline stage returns 0 whatever the earlier commands did.
function cannotFail(stage, piped) {
  const [head] = stage
  if (['true', ':', 'echo', 'printf'].includes(head)) return true
  return (piped && PIPE_SINKS.has(head)) || exitsZero(stage)
}

// Returns why a check can pass without testing anything, or '' when it can fail.
function vacuousReason(check) {
  const words = shellWords(check)
  if (!words) return 'it has an unclosed quote'
  const commands = [{ op: '', words: [] }]
  for (const w of words) {
    if (COMMAND_OPS.includes(w)) commands.push({ op: w, words: [] })
    else commands[commands.length - 1].words.push(w)
  }
  const shapes = commands.map(({ words: command }) => pipelineStages(withoutRedirects(unparen(command))))
  if (shapes.every((stages) => stages.every((stage, i) => cannotFail(stage, i > 0)))) return 'every command in it always succeeds'
  let guarded = new Set()
  for (const [index, { op, words: command }] of commands.entries()) {
    const last = index === commands.length - 1
    const shape = shapes[index]
    const tail = shape[shape.length - 1]
    if (tail) {
      const quiet = cannotFail(tail, shape.length > 1)
      if (shape.length === 1 && op !== '&&' && exitsZero(tail)) return 'it exits 0 whatever the earlier commands return'
      if (op === '||' && quiet) return 'it ends in an always-true fallback, which hides every failure'
      if (shape.length > 1 && quiet) return `its pipeline ends in ${tail[0]}, which hides a failed earlier stage`
      if (op !== '&&' && last && quiet) return 'its last command always succeeds'
    }
    if (op !== '&&' || command[0] === 'cd') guarded = new Set()
    const negated = command[0] === '!'
    const body = negated ? command.slice(1) : command
    const stages = [[]]
    for (const w of body) {
      if (w === '|') stages.push([])
      else stages[stages.length - 1].push(w)
    }
    if (!negated) {
      const path = guardedPath(body)
      if (path) guarded.add(path)
      continue
    }
    const search = searchOf(stages[stages.length - 1])
    if (!search) continue
    if (stages.length > 1) return `it negates a pipeline into ${search.tool}, which passes when the producer fails`
    if (search.stdin) return `it negates ${search.tool} with no file, which reads empty input`
    const open = search.paths.filter((p) => !guarded.has(p))
    if (open.length) return `it negates ${search.tool} over ${open.join(', ')} with no existence test of that path earlier in the same && chain`
  }
  return ''
}

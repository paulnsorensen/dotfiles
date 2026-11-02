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
// unrouted is true when a finding that needs cure has no owner. An unowned low that needs no cure stays out.
// unrouted is also true when the result claims medium+ findings or contained lows that its list does not carry.
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
// unsafeCheck fails closed. A structural layer rejects shapes that hide a command.
// An allowlist then classifies every simple command: it passes only when its head and flags are read-only.
// The layers are defense in depth; the judge agent definition is the other guard.

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
// shellWords prefixes an unquoted glob character with this mark, so a glob in a command head stays visible after dequoting.
const GLOB_MARK = String.fromCharCode(0xe000)
const plain = (w) => w.split(GLOB_MARK).join('')
const FILE_REDIRECT_RE = />(?!>?\s*\/dev\/null(?![^\s;|&)])|&(?:\d+|-)(?![^\s;|&)]))/
const BRACE_RE = /\{[^{}\s]*(?:,|\.\.)[^{}\s]*\}/

const ALLOWED_WRAPPERS = new Set(['env', 'command', 'time', 'xargs', 'nice', 'timeout', 'stdbuf', 'ionice'])
const WRAPPER_VALUE_OPTS = {
  xargs: ['-I', '-L', '-n', '-P', '-s', '-E', '-d', '-a', '--max-args', '--max-procs', '--max-lines', '--max-chars', '--delimiter', '--arg-file'],
  env: ['-u', '-C', '--unset', '--chdir'],
  timeout: ['-s', '-k', '--signal', '--kill-after'],
  nice: ['-n', '--adjustment'],
  stdbuf: ['-i', '-o', '-e', '--input', '--output', '--error'],
  ionice: ['-c', '-n', '-p', '-P', '--class', '--classdata', '--pid', '--pgid'],
}
// These heads have no flag that writes or runs a program. Only they may run under xargs, whose input adds arguments.
const READ_HEADS = new Set(['test', '[', 'true', 'false', 'grep', 'cat', 'head', 'tail', 'wc', 'ls', 'stat', 'diff', 'cmp', 'echo', 'printf', 'basename', 'dirname', 'realpath', 'readlink'])
const GIT_VALUE_OPTS = new Set(['-C', '--git-dir', '--work-tree', '--namespace', '--super-prefix'])
const GIT_READ = new Set(['status', 'log', 'diff', 'show', 'rev-parse', 'ls-files', 'ls-tree', 'grep', 'merge-base', 'describe', 'blame', 'shortlog', 'for-each-ref', 'cat-file', 'branch'])
const GH_READ = new Map([['pr', new Set(['view', 'list', 'diff', 'checks', 'status'])], ['issue', new Set(['view', 'list'])], ['run', new Set(['view', 'list'])]])
const GH_VALUE_OPTS = new Set(['-R', '--repo', '--hostname'])
const BRANCH_READ_FLAGS = new Set(['-a', '-r', '-v', '-vv', '--all', '--remotes', '--verbose', '--show-current', '--list'])
const BRANCH_COMMIT_FLAGS = new Set(['--contains', '--no-contains', '--merged', '--no-merged'])

// Only the read-only branch forms pass. A bare word names a branch to create, unless --list makes it a pattern.
function branchMutates(rest) {
  const listing = rest.includes('--list')
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i]
    if (BRANCH_COMMIT_FLAGS.has(arg)) { if (rest[i + 1] !== undefined && !rest[i + 1].startsWith('-')) i++ } else if (BRANCH_READ_FLAGS.has(arg)) continue
    else if (listing && !arg.startsWith('-')) continue
    else return true
  }
  return false
}

// Skips allowed wrappers and their options so the real command head shows. An env split-string option hides a command, so it fails.
function unwrap(input) {
  const words = [...input]
  let i = 0
  let viaXargs = false
  while (ALLOWED_WRAPPERS.has(words[i]?.toLowerCase())) {
    const wrapper = words[i++].toLowerCase()
    if (wrapper === 'xargs') viaXargs = true
    const valued = WRAPPER_VALUE_OPTS[wrapper] ?? []
    while (i < words.length && (words[i].startsWith('-') || (wrapper === 'env' && ASSIGN_RE.test(words[i])))) {
      const word = words[i]
      if (wrapper === 'env') {
        if (/^--s/.test(word)) return { hit: hit('env split-string option', word) }
        if (/^-[^-]/.test(word)) {
          // A short cluster such as -iS or -vu: S takes a command string, u and C take a value.
          const letters = [...word.slice(1)]
          const k = letters.findIndex((c) => c === 'S' || c === 'u' || c === 'C')
          if (k >= 0) {
            if (letters[k] === 'S') return { hit: hit('env split-string option', word) }
            i += k === letters.length - 1 ? 2 : 1
            continue
          }
        }
      }
      const eq = word.startsWith('--') ? word.indexOf('=') : -1
      const opt = eq < 0 ? word : word.slice(0, eq)
      i += eq < 0 && valued.includes(opt) ? 2 : 1
    }
    if (wrapper === 'timeout' && /^\d+(?:\.\d+)?[smhd]?$/.test(words[i] ?? '')) i++
  }
  return { words: words.slice(i), viaXargs }
}

// Reads the git subcommand from tokens, so the cost stays linear in the option count.
function gitHit(rawArgs) {
  let i = 0
  for (; i < rawArgs.length && rawArgs[i].startsWith('-'); i++) {
    const arg = plain(rawArgs[i])
    if ((arg.startsWith('-c') && !arg.startsWith('--')) || arg.startsWith('--config-env') || arg.startsWith('--exec-path')) return hit('git config override', arg)
    if (GIT_VALUE_OPTS.has(arg)) i++
  }
  const sub = rawArgs[i]
  if (sub === undefined) return null
  const rest = rawArgs.slice(i + 1).map(plain)
  if (!GIT_READ.has(sub)) return hit('git mutation', `git ${plain(sub)}`)
  if (sub === 'branch' && branchMutates(rest)) return hit('git mutation', 'git branch')
  if (sub === 'cat-file' && !['-e', '-t', '-p'].includes(rest[0])) return hit('git mutation', 'git cat-file')
  const output = rest.find((a) => /^--output(?:=|$)/.test(a) || (sub === 'grep' && /^(?:-O|--open-files-in-pager)/.test(a)))
  return output ? hit('git option that writes a file or runs a program', output) : null
}

// Reads the gh group and verb from the operands, so a flag before or between them does not hide them.
function ghHit(rawArgs) {
  const args = rawArgs.map(plain)
  const operands = []
  for (let i = 0; i < args.length && operands.length < 2; i++) {
    if (!args[i].startsWith('-')) operands.push(rawArgs[i])
    else if (GH_VALUE_OPTS.has(args[i])) i++
  }
  const [group, verb] = operands
  if (group === 'api') return ghApiHit(args)
  if (GH_READ.get(group)?.has(verb)) return null
  return hit('GitHub mutation', `gh ${plain(group ?? '')} ${plain(verb ?? '')}`.trim())
}

function ghApiHit(args) {
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (/^--(?:field|raw-field|input)(?:=|$)/.test(arg) || /^-[a-zA-Z]*[fF]/.test(arg)) return hit('GitHub API field write', arg)
    const method = /^--method(?:=(.*))?$/.exec(arg) ?? /^-[a-zA-Z]*X=?(.*)$/.exec(arg)
    if (method && (method[1] || args[i + 1] || '').toUpperCase() !== 'GET') return hit('GitHub API write', arg)
  }
  return null
}

// Finds the end of a delimited sed section, where a backslash escapes the next character. Returns -1 when it never closes.
function sedSectionEnd(p, from, delim) {
  for (let i = from; i < p.length; i++) {
    if (p[i] === '\\') i++
    else if (p[i] === delim) return i + 1
  }
  return -1
}
const digitsEnd = (p, i) => {
  while (/[0-9]/.test(p[i] ?? '')) i++
  return i
}

// Walks a sed program. Only print, delete, quit, hold, substitute, and transliterate commands pass, and s flags exclude e, w, and W.
// Any other command, or a shape the walk cannot read, counts as unsafe.
function sedProgramBad(p) {
  let i = 0
  while (i < p.length) {
    if (/[\s;{}]/.test(p[i])) { i++; continue }
    for (let n = 0; n < 2; n++) {
      if (p[i] === '/' || p[i] === '\\') {
        const delim = p[i] === '\\' ? p[++i] : '/'
        if (delim === undefined) return true
        i = sedSectionEnd(p, i + 1, delim)
        if (i < 0) return true
        while (/[IM]/.test(p[i] ?? '')) i++
      } else if (p[i] === '$') i++
      else if (/[0-9]/.test(p[i] ?? '') || (n === 1 && /[+~]/.test(p[i] ?? ''))) {
        i = digitsEnd(p, /[+~]/.test(p[i]) ? i + 1 : i)
        if (p[i] === '~') i = digitsEnd(p, i + 1)
      } else break
      if (p[i] !== ',') break
      i++
    }
    while (/[\s!]/.test(p[i] ?? '')) i++
    const cmd = p[i++]
    if (cmd === 's' || cmd === 'y') {
      const delim = p[i]
      if (delim === undefined || /[\s\\]/.test(delim)) return true
      i = sedSectionEnd(p, i + 1, delim)
      if (i >= 0) i = sedSectionEnd(p, i, delim)
      if (i < 0) return true
      if (cmd === 's') {
        for (; /[a-zA-Z0-9]/.test(p[i] ?? ''); i++) if (!/[gpiImM0-9]/.test(p[i])) return true
      }
    } else if (cmd === 'q' || cmd === 'Q' || cmd === 'l') i = digitsEnd(p, i)
    else if (cmd === 'b' || cmd === 't' || cmd === 'T') { while (i < p.length && !/[\s;}]/.test(p[i])) i++ } else if (cmd === undefined || !'pdDPnNgGhHx='.includes(cmd)) return true
  }
  return false
}

function sedHit(args) {
  const programs = []
  const operands = []
  let explicit = false
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (arg === '--') { operands.push(...args.slice(i + 1)); break }
    if (arg === '-e' || arg === '--expression') { programs.push(args[++i] ?? ''); explicit = true } else if (arg.startsWith('--expression=')) { programs.push(arg.slice(13)); explicit = true } else if (/^-[nErszu]+$/.test(arg) || /^--(?:quiet|silent|regexp-extended|separate|null-data|unbuffered|posix|sandbox|debug)$/.test(arg)) continue
    else if (/^-[nErszu]*e/.test(arg)) { programs.push(arg.replace(/^-[nErszu]*e/, '') || (args[++i] ?? '')); explicit = true } else if (/^-[a-zA-Z]*i|^--in-place/.test(arg)) return hit('in-place edit', arg)
    else if (arg.startsWith('-') && arg !== '-') return hit('sed option that writes or runs', arg)
    else operands.push(arg)
  }
  if (!explicit) programs.push(operands.shift() ?? '')
  const bad = programs.find(sedProgramBad)
  return bad === undefined ? null : hit('sed command that writes or runs', bad)
}

function awkHit(args) {
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (arg === '-F') i++
    else if (/^(?:-f|--file|-i|--include|-l|--load|-E|--exec)/.test(arg) || (!arg.startsWith('-F') && /\bsystem\b|\bgetline\b|\bprintf?\b[^;}\n]*>|[|@]/.test(arg))) return hit('awk program that writes or runs a command', arg)
  }
  return null
}

// uniq writes to its second operand, so it takes at most one operand.
function uniqHit(args) {
  let operands = 0
  for (let i = 0; i < args.length; i++) {
    if (/^-[fsw]$|^--(?:skip-fields|skip-chars|check-chars)$/.test(args[i])) i++
    else if (!args[i].startsWith('-') || args[i] === '-') operands++
  }
  return operands > 1 ? hit('uniq output file', args.join(' ').slice(0, 24)) : null
}

const notListed = (text) => hit('command not on the read-only allowlist', text)
const allow = () => null
const flagged = (name, re) => (args) => {
  const found = args.find((a) => re.test(a))
  return found === undefined ? null : hit(name, found)
}
const gated = (head, ok) => (args) => (ok(args) ? null : notListed(`${head} ${args.slice(0, 2).join(' ')}`.trim()))
const pkgTest = (args) => args[0] === 'test' || (args[0] === 'run' && /^test(?::[\w:-]*)?$/.test(args[1] ?? ''))
const nodeTest = (args) => args.includes('--test') && !args.some((a) => /^(?:-[a-zA-Z]*[ep]|-r|--(?:eval|print|require|import|loader|experimental-loader))$/.test(a))

// Every head a check may use. A head missing here fails closed.
const HEAD_RULES = new Map([
  ...[...READ_HEADS].map((h) => [h, allow]),
  ['rg', flagged('rg option that runs a program', /^--(?:pre|hostname-bin)(?:=|$)/)],
  ['file', flagged('file option that writes a file', /^-[a-zA-Z]*C|^--compile/)],
  ['jq', flagged('in-place edit', /^-[a-zA-Z]*i|^--in-place/)],
  ['find', flagged('find action that writes or runs a command', /^-(?:exec|execdir|ok|okdir|delete|fprint0?|fprintf|fls)$/)],
  ['sort', flagged('sort option that writes a file or runs a program', /^-[a-zA-Z0-9]*o|^--(?:output|compress-program)/)],
  ['sed', sedHit],
  ['awk', awkHit],
  ['uniq', uniqHit],
  ['node', gated('node', nodeTest)],
  ['npm', gated('npm', pkgTest)],
  ['pnpm', gated('pnpm', pkgTest)],
  ['yarn', gated('yarn', pkgTest)],
  ['just', gated('just', (a) => a.length > 0 && !a[0].startsWith('-'))],
  ...['[[', 'exit', ':', 'cd', 'bats'].map((h) => [h, allow]),
  ['pytest', allow],
  ['python', gated('python', (a) => a[0] === '-m' && a[1] === 'pytest')],
  ['cargo', gated('cargo', (a) => a[0] === 'test')],
  ['go', gated('go', (a) => a[0] === 'test')],
  ['make', gated('make', (a) => a[0] === 'test')],
  ['git', (args, rawArgs) => gitHit(rawArgs)],
  ['gh', (args, rawArgs) => ghHit(rawArgs)],
])

const COMMAND_OPS = ['&&', '||', ';', '&']
const unparen = (words) => words.map((w) => w.replace(/^\(+|\)+$/g, '')).filter(Boolean)
// An operator token is an object, so a quoted ; stays an ordinary word.
const op = (text) => ({ op: text })

// Splits a check into words and operator tokens. A glob character carries GLOB_MARK. Returns null on an open quote.
function shellTokens(check) {
  const words = []
  let word = null
  const end = () => { if (word !== null) words.push(word === GLOB_MARK + '[' || word === GLOB_MARK + '[' + GLOB_MARK + '[' ? word.split(GLOB_MARK).join('') : word); word = null }
  for (let i = 0; i < check.length; i++) {
    const c = check[i]
    const pair = check.slice(i, i + 2)
    if (c === '\n') { end(); words.push(op(';')) }
    else if (/\s/.test(c)) end()
    else if (pair === '&&' || pair === '||') { end(); words.push(op(pair)); i++ }
    else if (pair === '|&') { end(); words.push(op('|')); i++ }
    else if (c === '&' && check[i - 1] !== '>' && check[i - 1] !== '<' && check[i + 1] !== '>') { end(); words.push(op('&')) }
    else if (c === ';' || c === '|') { end(); words.push(op(c)) }
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
    else word = (word ?? '') + (/[*?[]/.test(c) ? GLOB_MARK + c : c)
  }
  end()
  return words
}

// Splits a check into words and the operators && || ; | &, with POSIX quotes removed. A newline counts as ;. Returns null on an open quote.
function shellWords(check) {
  return shellTokens(check)?.map((t) => (typeof t === 'object' ? t.op : plain(t))) ?? null
}

// Classifies one simple command against the allowlist. Returns a hit or null.
function commandHit(raw) {
  const words = unparen(raw)
  while (words[0] === '!') words.shift()
  if (!words.length) return null
  if (ASSIGN_RE.test(words[0])) return hit('NAME=value prefix', words[0])
  const unwrapped = unwrap(words)
  if (unwrapped.hit) return unwrapped.hit
  const [rawHead, ...rawArgs] = unwrapped.words
  if (rawHead === undefined) return null
  const head = rawHead.toLowerCase()
  const key = /^python[\d.]*$/.test(head) ? 'python' : head
  const rule = HEAD_RULES.get(key)
  if (!rule) return notListed(plain(head).slice(0, 40))
  if (unwrapped.viaXargs && !READ_HEADS.has(key)) return hit('xargs command that its input can change', plain(head).slice(0, 40))
  return rule(rawArgs.map(plain), rawArgs)
}

// Returns { name, text } for the first unsafe shape in a check, or null.
function unsafeCheck(check) {
  const structural = structuralHit(check)
  if (structural) return structural
  const masked = maskQuotes(check, true)
  // Only fd duplication (>&1, 2>&1, >&-) and a redirect to the whole token /dev/null stay allowed.
  const redirect = FILE_REDIRECT_RE.exec(masked)
  if (redirect) return hit('output redirection to a file', masked.slice(redirect.index, redirect.index + 24).trim())
  const brace = BRACE_RE.exec(masked)
  if (brace) return hit('brace expansion', brace[0])
  const comment = /(?:^|[\s;&|(])#/.exec(masked)
  if (comment) return hit('shell comment', masked.slice(comment.index, comment.index + 24).trim())
  const subshell = /[<>]\(|[^\s(;&|]\(/.exec(masked)
  if (subshell) return hit('process substitution or function definition', masked.slice(subshell.index, subshell.index + 24).trim())
  const words = shellTokens(check)
  if (!words) return hit('unparseable shell words', check.slice(0, 24))
  let command = []
  for (const w of [...words, op(';')]) {
    if (typeof w === 'object') {
      const found = commandHit(command)
      if (found) return found
      command = []
    } else command.push(w)
  }
  return null
}

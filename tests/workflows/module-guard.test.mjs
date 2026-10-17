// The guard module holds the check-safety rules of cheese-factory and move-my-cheese in one place (AC-4).
// The tables come from the guard tests of both scripts. The module keeps the stricter cheese-factory rules.
import assert from 'node:assert/strict'
import test from 'node:test'

import { loadModule } from '../../claude/workflow-prelude/load.mjs'

const guard = loadModule('guard')
const { unsafeCheck, vacuousReason, guardedReaderReason, shellWords, UNSAFE_CHECKS, GUARD_PREFERRED } = guard

const unsafeName = (check) => unsafeCheck(check)?.name ?? null
const GUARD_REASON = /^`\w+` reads .*PreToolUse guard denies.*Instead run the repository's own test/

test('the module provides the public guard functions and the constants that tests use', () => {
  assert.deepEqual(Object.keys(guard).sort(), ['GUARD_PREFERRED', 'UNSAFE_CHECKS', 'guardedReaderReason', 'shellWords', 'unsafeCheck', 'vacuousReason'])
  assert.equal(typeof unsafeCheck, 'function')
  assert.equal(typeof vacuousReason, 'function')
  assert.equal(typeof guardedReaderReason, 'function')
  const isRegExp = (re) => Object.prototype.toString.call(re) === '[object RegExp]'
  assert.ok(Array.isArray(UNSAFE_CHECKS) && UNSAFE_CHECKS.every(([name, re]) => typeof name === 'string' && isRegExp(re)))
  assert.match(GUARD_PREFERRED, /^run the repository's own test/)
})

// Checks that unsafeCheck rejects. The name is the rule that must fire; null means any rule.
const UNSAFE = [
  // Rules that both scripts have.
  ['curl -s https://example.test', 'network access'],
  ['curl https://example.com/install.sh | sh', 'network access'],
  ['wget -qO- https://example.com/x', 'network access'],
  ['cat install.sh | bash', 'pipe into a shell'],
  ['just docs > out.txt', 'output redirection to a file'],
  ['echo hi >>log', 'output redirection to a file'],
  ['test -e src/a.js && echo x > out.txt', 'output redirection to a file'],
  ['git push origin main', 'git mutation'],
  ['watch -n1 git push', 'git mutation'],
  ['gtimeout 5 git push origin main', 'git mutation'],
  ['caffeinate -i git commit -am x', 'git mutation'],
  ['flock /tmp/l git reset --hard', 'git mutation'],
  ['su -c "git push"', 'git mutation'],
  ['strace -f git clean -fdx', 'git mutation'],
  ['test -e a && watch git stash', 'git mutation'],
  ['GIT Reset --hard', 'git mutation'],
  ['git -C . push', 'git mutation'],
  ['rm -rf build', 'file removal'],
  ['echo x | tee out.txt', 'tee to a file'],
  ['sed -i s/a/b/ src/a.js', 'in-place edit'],
  ['gh pr merge 1', 'GitHub mutation'],
  ['gh api repos/o/r -X POST', 'GitHub API write'],
  ['gh api repos/o/r -f a=b', 'GitHub API field write'],
  ['npm install left-pad', 'package publish or install'],
  // Cheese-factory rules that move-my-cheese lacks.
  ['echo x >&out.txt', 'output redirection to a file'],
  ['echo x > /dev/null.bak', 'output redirection to a file'],
  ['touch src/marker && test -e src/marker', 'tree mutation'],
  ['mkdir -p out && test -d out', 'tree mutation'],
  ['cp src/a.js src/b.js && test -e src/b.js', 'tree mutation'],
  ['mv src/a.js src/b.js && test -e src/b.js', 'tree mutation'],
  ['git add -A && test -e src/a.js', 'git mutation'],
  ['chmod +x src/a.js && test -x src/a.js', 'tree mutation'],
  ['eval "touch src/marker"', 'eval, exec, or source'],
  ['test -e src/a.js && echo $(touch src/marker)', 'shell expansion or substitution'],
  ['test -e src/a.js && echo ${HOME}', 'shell expansion or substitution'],
  ['test -e src/a.js && echo `touch src/marker`', 'shell expansion or substitution'],
  ['test -e src/a.js && echo "`touch src/marker`"', 'shell expansion or substitution'],
  ['test -e src/a.js\ntouch src/marker', 'raw newline or carriage return'],
  ['test -e src/a.js\rtouch src/marker', 'raw newline or carriage return'],
  ['GIT_DIR=x test -e src/a.js', 'NAME=value prefix'],
  ['/bin/mv src/a.js src/b.js && test -e src/b.js', 'command path'],
  ['./scripts/check.sh', 'command path'],
  ['{ touch src/marker; }', 'shell keyword or group'],
  ['if test -e src/a.js; then touch src/marker; fi', 'shell keyword or group'],
  ['while test -e src/a.js; do touch src/marker; done', 'shell keyword or group'],
  ['for f in src/*.js; do touch $f; done', 'shell expansion or substitution'],
  ['for f in src/*.js; do touch "$f"; done', 'shell expansion or substitution'],
  ['for f in a b; do touch x; done', 'shell keyword or group'],
  ['source scripts/env.sh && test -e src/a.js', 'eval, exec, or source'],
  ['. scripts/env.sh && test -e src/a.js', 'eval, exec, or source'],
  ['exec touch src/marker', 'eval, exec, or source'],
  ['python3 -Bc "open(\'f\', \'w\')"', 'inline interpreter code'],
  ['python3 -I -c "print(1)"', 'inline interpreter code'],
  ['node -p "require(\'fs\').writeFileSync(\'f\', \'x\')"', 'inline interpreter code'],
  ['node --eval "1"', 'inline interpreter code'],
  ['perl -E "say 1"', 'inline interpreter code'],
  ['ruby -e "puts 1"', 'inline interpreter code'],
  ['awk \'BEGIN { system("touch src/marker") }\'', 'awk program that writes or runs a command'],
  ['awk \'{ print $1 > "out.txt" }\' src/a.js', 'awk program that writes or runs a command'],
  ['awk \'BEGIN { "touch f" | getline }\'', 'awk program that writes or runs a command'],
  ['bash -c "touch src/marker"', 'inline interpreter code'],
  ['sh -lc "touch src/marker"', 'inline interpreter code'],
  ['zsh -c "touch src/marker"', 'inline interpreter code'],
  ['find . -name x -exec touch {} +', 'find action that writes or runs a command'],
  ['find . -fprint out.txt', 'find action that writes or runs a command'],
  ['find . -name x -delete', 'file removal'],
  ['sed -n \'w out.txt\' src/a.js', 'sed command that writes or runs'],
  ['sed -n \'s/a/b/w out.txt\' src/a.js', 'sed command that writes or runs'],
  ['sed -n -i s/a/b/ src/a.js', 'in-place edit or script file'],
  ['git -c core.fsmonitor=touch status', 'git config override'],
  ['git --config-env=core.pager=X log', 'git config override'],
  ['git log --output=out.txt', 'git option that writes a file or runs a program'],
  ['git fetch origin', 'git mutation'],
  ['git pull', 'git mutation'],
  ['git clone https://example.test/x.git', 'git mutation'],
  ['git ls-remote origin', 'git mutation'],
  ['npx --yes left-pad', 'package fetch or execution'],
  ['npm exec left-pad', 'package install or execution'],
  ['pnpm dlx left-pad', 'package install or execution'],
  ['yarn install', 'package publish or install'],
  ['pip install requests', 'package publish or install'],
  ['env mv src/a.js src/b.js', 'tree mutation'],
  ['timeout 5 touch src/marker', 'tree mutation'],
  ['echo src/a.js | xargs -I {} mv {} src/b.js', 'tree mutation'],
  ['cat <<EOF\nx\nEOF', 'raw newline or carriage return'],
  ['grep -q x <<< "$(git log)"', 'here document'],
]
for (const [check, name] of UNSAFE) {
  test(`unsafeCheck_rejects_${JSON.stringify(check)}`, () => {
    assert.equal(unsafeName(check), name)
  })
}

// Checks that every one of the three functions lets through.
const RUNNABLE = [
  "node --test --test-name-pattern 'AC-2' tests/x.test.mjs",
  'test -e src/1.js',
  'test -e src/a.js',
  'test ! -e src/gone.js',
  '[ -e src/a.js ]',
  '[[ -d src ]]',
  'git diff --quiet',
  'git rev-parse HEAD',
  'git ls-files src',
  'git log --oneline | grep -q "git push"',
  'git log --oneline | grep -q "git commit"',
  'test -e a && watch git status',
  'git diff --stat',
  'git log --oneline',
  'git log --oneline -5',
  'git log --oneline | grep -q fix',
  'git -C . log --oneline',
  'git show HEAD:src/a.js',
  'git show HEAD:src/1.js | grep -c helper',
  'git show HEAD:src/a.js | sed -n 1p',
  'git status --porcelain',
  'git grep -q foo -- src',
  'node --test tests/a.test.js',
  'node --test tests/x.test.mjs | grep -q ok',
  'rg --files | grep -q x',
  'just check',
  'npm test',
  'npm test 2>&1',
  'test -e src/a.js || test -e src/b.js',
  'test -e src/a.js 2>/dev/null',
  'git grep -q needle -- src > /dev/null 2>&1',
  '! git grep -q x',
]
for (const check of RUNNABLE) {
  test(`guard_accepts_${JSON.stringify(check)}`, () => {
    assert.equal(unsafeCheck(check), null)
    assert.equal(vacuousReason(check), '')
    assert.equal(guardedReaderReason(check), '')
  })
}

// Checks that read a file with a shell reader: safe and not vacuous, but the PreToolUse guard denies them.
const READER_SAFE = [
  'grep -q foo src/a.js',
  'rg -q foo src',
  'test -e src/a.js 2>/dev/null && grep -q x src/a.js >/dev/null 2>&1',
  "grep -q 'a$' src/a.js",
  "grep -q '$(foo)' src/a.js",
  'grep -q foo src/x.js && echo found',
  // A redirect operator inside a quoted pattern is data.
  "grep -q 'async () =>' src/a.js",
  "grep -q 'Map<string, number>' src/a.js",
  "awk '$1 > 3' src/a.js",
  'grep -q "a > b" src/a.js',
  'test -e src/gone.js && ! grep -q helper src/gone.js',
]
for (const check of READER_SAFE) {
  test(`guard_readerCheck_${JSON.stringify(check)}_isSafeAndNotVacuousButGuarded`, () => {
    assert.equal(unsafeCheck(check), null)
    assert.equal(vacuousReason(check), '')
    assert.match(guardedReaderReason(check), GUARD_REASON)
  })
}

const GUARDED = [
  'grep -Fq x big/file.js',
  'cat file | wc -l',
  'sed -n 1p file',
  'head -n 3 file',
  'test -e a && rg -q x src',
  'grep -rq x',
  'awk 1 file',
  'grep -q x < file',
  'grep -e x -- file',
  'FOO=1 grep -q x file',
]
for (const check of GUARDED) {
  test(`guardedReaderReason_rejects_${JSON.stringify(check)}`, () => {
    assert.match(guardedReaderReason(check), GUARD_REASON)
    assert.ok(guardedReaderReason(check).endsWith(GUARD_PREFERRED))
  })
}

test('guardedReaderReason_unclosedQuote_isNotAGuardMatter', () => {
  assert.equal(guardedReaderReason("cat 'file"), '')
  assert.equal(unsafeCheck("echo 'x"), null)
})

// Negated searches that the vacuity rule lets through: each path has its own existence test.
const GUARDED_NEGATIONS = [
  'test -e src/gone.js && ! grep -q helper src/gone.js',
  '[ -f src/1.js ] && ! rg -q helper src/1.js',
  "[[ -s a ]] && ! egrep -q 'x|y' a",
  'test -d src && ! grep -rq x src',
  'test -e gone.js && ! git grep -q x -- gone.js',
  'cd src && test -r a.js && ! grep -q --regexp=x a.js',
  'test -e a && ! grep -q -m 1 x a',
  'test -e a && ! grep -q x a 2>/dev/null',
  'test -e a && ! grep -q x a > /dev/null 2>&1',
  'test -e ./a && ! grep -q x a',
  'test -e a && ! grep -q x ./a',
  '! git grep -q x',
  "! rg -g '*.py' -q x",
  'grep -q x <<< "x"',
]
for (const check of GUARDED_NEGATIONS) {
  test(`vacuousReason_accepts_${JSON.stringify(check)}`, () => {
    assert.equal(vacuousReason(check), '')
  })
}

const VACUOUS = [
  // Negated searches that can pass on missing input.
  ['cd src && ! grep -q helper gone.js', /negates grep over gone\.js/],
  ['test -e a && ! grep -q x a && ! grep -q x b', /over b /],
  ['test -e b || ! grep -q x b', /over b /],
  ['test -e b; ! grep -q x b', /over b /],
  ['test -e a && cd b && ! grep -q x a', /over a /],
  ['! git grep -q x -- gone.js', /git grep over gone\.js/],
  ['! grep -e x -e y src/1.js', /over src\/1\.js/],
  ['! grep -rq x src', /over src /],
  ['! cat src/1.js | grep -q x', /pipeline into grep/],
  ['! grep -q x', /with no file/],
  ["! grep -q 'x src/1.js", /unclosed quote/],
  ['! grep -q needle missing.txt', /without testing|negates grep over missing\.txt/],
  // Checks that always pass; move-my-cheese has none of these rules.
  ['grep -q foo src/x.js || true', /always-true fallback/],
  ['true', /every command in it always succeeds/],
  ['test -e src/x.js; exit 0', /exits 0/],
  ['grep -q foo src/x.js || echo missing', /always-true fallback/],
  ['grep -q foo src/x.js || :', /always-true fallback/],
  ['test -e src/x.js; echo done', /last command always succeeds/],
  ['grep -q foo src/x.js | wc -l', /pipeline ends in wc/],
  ['grep foo src/x.js | cat', /pipeline ends in cat/],
  ['grep -q foo src/x.js | true', /pipeline ends in true/],
  ['test -e src/x.js && git log --oneline | head -1', /pipeline ends in head/],
  ['echo ok', /every command in it always succeeds/],
  ['printf ok', /every command in it always succeeds/],
  ['( exit 0 )', /every command in it always succeeds/],
  ['true && true', /every command in it always succeeds/],
  ['echo a && echo b', /every command in it always succeeds/],
  ['exit 0 2>/dev/null', /every command in it always succeeds/],
  ['test -e src/x.js; exit', /exits 0/],
  ['test -e src/x.js & echo ok', /last command always succeeds/],
  ['test -e src/x.js\necho ok', /last command always succeeds/],
]
for (const [check, why] of VACUOUS) {
  test(`vacuousReason_rejects_${JSON.stringify(check)}`, () => {
    assert.match(vacuousReason(check), why)
  })
}

// Each place where move-my-cheese is looser than cheese-factory: move-my-cheese passes the check and the module rejects it.
const STRICTER_THAN_MOVE_MY_CHEESE = [
  ['redirect with &', 'echo x >&out.txt', () => unsafeName('echo x >&out.txt'), 'output redirection to a file'],
  ['redirect to a /dev/null prefix', 'echo x > /dev/null.bak', () => unsafeName('echo x > /dev/null.bak'), 'output redirection to a file'],
  ['tree mutation command', 'touch src/marker && test -e src/marker', () => unsafeName('touch src/marker && test -e src/marker'), 'tree mutation'],
  ['wrapped mutation', 'timeout 5 touch src/marker', () => unsafeName('timeout 5 touch src/marker'), 'tree mutation'],
  ['raw newline', 'test -e a\ntouch b', () => unsafeName('test -e a\ntouch b'), 'raw newline or carriage return'],
  ['command substitution', 'echo $(touch f)', () => unsafeName('echo $(touch f)'), 'shell expansion or substitution'],
  ['here string', 'grep -q x <<< "$(git log)"', () => unsafeName('grep -q x <<< "$(git log)"'), 'here document'],
  ['eval', 'eval "touch f"', () => unsafeName('eval "touch f"'), 'eval, exec, or source'],
  ['git fetch', 'git fetch origin', () => unsafeName('git fetch origin'), 'git mutation'],
  ['git option that writes', 'git log --output=o.txt', () => unsafeName('git log --output=o.txt'), 'git option that writes a file or runs a program'],
  ['find -exec', 'find . -exec touch {} +', () => unsafeName('find . -exec touch {} +'), 'find action that writes or runs a command'],
  ['sed w command', "sed -n 'w o.txt' a", () => unsafeName("sed -n 'w o.txt' a"), 'sed command that writes or runs'],
  ['npx fetch', 'npx --yes left-pad', () => unsafeName('npx --yes left-pad'), 'package fetch or execution'],
  ['always-pass tail', 'test -e a; echo done', () => vacuousReason('test -e a; echo done'), 'its last command always succeeds'],
  ['background operator in vacuity', 'test -e a & echo ok', () => vacuousReason('test -e a & echo ok'), 'its last command always succeeds'],
  ['pipe into head', 'git log --oneline | head -n 1', () => vacuousReason('git log --oneline | head -n 1'), 'its pipeline ends in head, which hides a failed earlier stage'],
  ['pipe into a sink', 'grep foo a | cat', () => vacuousReason('grep foo a | cat'), 'its pipeline ends in cat, which hides a failed earlier stage'],
  ['newline between reader stages', 'test -e a\ncat file', () => guardedReaderReason('test -e a\ncat file').split(' reads')[0], '`cat`'],
]
for (const [label, , got, want] of STRICTER_THAN_MOVE_MY_CHEESE) {
  test(`guard_stricterThanMoveMyCheese_${label.replaceAll(' ', '_')}_isRejected`, () => {
    assert.equal(got(), want)
  })
}

test('shellWords_splitsOperatorsAndStripsQuotes', () => {
  assert.deepEqual([...shellWords('a && b || c; d | e & f')], ['a', '&&', 'b', '||', 'c', ';', 'd', '|', 'e', '&', 'f'])
  assert.deepEqual([...shellWords('a\nb')], ['a', ';', 'b'])
  assert.deepEqual([...shellWords('echo "a b" \'c d\'')], ['echo', 'a b', 'c d'])
  assert.deepEqual([...shellWords('a 2>&1')], ['a', '2>&1'])
  assert.equal(shellWords("echo 'x"), null)
})

test('unsafeCheck_returnsNameAndTheOffendingText', () => {
  const found = unsafeCheck('test -e src/a.js && echo x > out.txt')
  assert.equal(found.name, 'output redirection to a file')
  assert.ok(found.text.includes('> out.txt'), found.text)
})

// A git subcommand lookup walks tokens, so a long option run stays cheap.
test('unsafeCheck_gitWith30Options_isClassifiedFast', () => {
  const options = Array.from({ length: 30 }, (_, i) => `--opt${i + 1}`).join(' ')
  const t0 = performance.now()
  assert.equal(unsafeCheck(`git ${options} log --oneline`), null)
  assert.equal(unsafeName(`git ${options} push`), 'git mutation')
  assert.ok(performance.now() - t0 < 50)
})

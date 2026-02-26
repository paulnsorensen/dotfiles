# Prompt Recording Tape
# Records the zsh powerline prompt in various states for visual debugging.
# Usage: vhs vhs/prompt.tape   (or: bin/record-prompt)
#
# Scenes:
#   1. Non-git directory (path segment only)
#   2. Git repo — clean state (path + branch + time-since-commit)
#   3. Git repo — dirty working tree
#   4. Git repo — staged changes
#   5. Git repo — fresh commit (time resets)
#   6. Detached HEAD state

Output vhs/output/prompt.gif

Require vhs

Set Shell "zsh"
Set FontFamily "Hack Nerd Font Mono"
Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 20
Set TypingSpeed 40ms
Set Theme "Builtin Dark"

# ---------------------------------------------------------------------------
# Scene 1: Non-git directory
# ---------------------------------------------------------------------------

Sleep 1s
Type "# Scene 1: Non-git directory"
Enter
Sleep 500ms
Type "cd /tmp && pwd"
Enter
Sleep 1.5s

# ---------------------------------------------------------------------------
# Scene 2: Git repo — clean state
# ---------------------------------------------------------------------------

Type "# Scene 2: Git repo (clean)"
Enter
Sleep 500ms
Type "cd ~/Dev/dotfiles && git status --short"
Enter
Sleep 2s

# ---------------------------------------------------------------------------
# Scene 3: Git repo — dirty working tree
# ---------------------------------------------------------------------------

Type "# Scene 3: Dirty working tree"
Enter
Sleep 500ms
Type "echo 'vhs-test' >> /tmp/vhs-scratch && cp /tmp/vhs-scratch .vhs-scratch"
Enter
Sleep 1s
Type "git status --short"
Enter
Sleep 2s

# ---------------------------------------------------------------------------
# Scene 4: Staged changes
# ---------------------------------------------------------------------------

Type "# Scene 4: Staged changes"
Enter
Sleep 500ms
Type "git add .vhs-scratch && git status --short"
Enter
Sleep 2s

# ---------------------------------------------------------------------------
# Scene 5: Clean up test file
# ---------------------------------------------------------------------------

Type "# Cleanup"
Enter
Sleep 500ms
Type "git reset HEAD .vhs-scratch && rm -f .vhs-scratch /tmp/vhs-scratch"
Enter
Sleep 2s

# ---------------------------------------------------------------------------
# Scene 6: Detached HEAD
# ---------------------------------------------------------------------------

Type "# Scene 6: Detached HEAD"
Enter
Sleep 500ms
Type "git checkout HEAD~1 2>/dev/null"
Enter
Sleep 2s
Type "git checkout - 2>/dev/null"
Enter
Sleep 2s

# Final pause to capture last prompt
Sleep 2s

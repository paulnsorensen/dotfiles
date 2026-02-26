# Prompt Comparison Tape: zsh powerline vs starship
# Records both prompt styles for visual comparison.
# Usage: record-prompt vhs/prompt-compare.tape

Output vhs/output/prompt-compare.gif

Set Shell "zsh"
Set FontFamily "Hack Nerd Font Mono"
Set FontSize 16
Set Width 1400
Set Height 900
Set Padding 20
Set TypingSpeed 50ms

# Use a neutral dark theme — Chocolate Donut uses 256 color codes
# that need a dark background but not one that clashes.
Set Theme "Builtin Dark"

# Wait for zshrc to finish (it ends with `clear`)
Sleep 3s

# ═══════════════════════════════════════════════════════════════════════════════
# PART 1: Custom zsh powerline prompt (default)
# ═══════════════════════════════════════════════════════════════════════════════

Type "echo '--- ZSH POWERLINE PROMPT ---'"
Enter
Sleep 1.5s

# Non-git directory
Type "cd /tmp"
Enter
Sleep 2s

# Git repo — show branch + time since commit
Type "cd ~/Dev/dotfiles"
Enter
Sleep 2s

# Show git log for context
Type "git log --oneline -3"
Enter
Sleep 2s

# ═══════════════════════════════════════════════════════════════════════════════
# PART 2: Switch to starship
# ═══════════════════════════════════════════════════════════════════════════════

Type "echo '--- SWITCHING TO STARSHIP ---'"
Enter
Sleep 1.5s

# Activate starship
Type "source ~/Dev/dotfiles/vhs/switch-to-starship.zsh"
Enter
Sleep 3s

# Non-git directory
Type "cd /tmp"
Enter
Sleep 2s

# Git repo
Type "cd ~/Dev/dotfiles"
Enter
Sleep 2.5s

# Show git log
Type "git log --oneline -3"
Enter
Sleep 2s

# Final pause
Sleep 2s

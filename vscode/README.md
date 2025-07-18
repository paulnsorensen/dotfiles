# VS Code Configuration

This directory contains VS Code configuration files for a vim-centric development setup.

## Installation

### macOS
Copy the configuration files to your VS Code settings directory:

```bash
# Create VS Code settings directory if it doesn't exist
mkdir -p ~/Library/Application\ Support/Code/User

# Copy configuration files
cp vscode/settings.json ~/Library/Application\ Support/Code/User/settings.json
cp vscode/keybindings.json ~/Library/Application\ Support/Code/User/keybindings.json
cp vscode/extensions.json ~/Library/Application\ Support/Code/User/extensions.json
```

### Linux
```bash
# Create VS Code settings directory if it doesn't exist
mkdir -p ~/.config/Code/User

# Copy configuration files
cp vscode/settings.json ~/.config/Code/User/settings.json
cp vscode/keybindings.json ~/.config/Code/User/keybindings.json
cp vscode/extensions.json ~/.config/Code/User/extensions.json
```

## Key Features

### Vim Bindings
- Full vim emulation via the Vim extension
- `jj` to escape from insert mode
- Space as leader key
- Relative line numbers
- System clipboard integration

### Sublime Text-style Shortcuts
- **Cmd+T**: Quick file search (like Sublime Text)
- **Cmd+R**: Symbol search in current file
- **Cmd+Shift+R**: Symbol search in workspace
- **Cmd+Shift+T**: Command palette

### File Navigation
- **Ctrl+J/K**: Navigate in quick open and suggestions (vim-style)
- **Cmd+B**: Toggle sidebar
- **Cmd+J**: Toggle panel
- **Cmd+`**: Toggle terminal

### Extensions
Install recommended extensions by opening the Extensions view (Cmd+Shift+X) and searching for "@recommended".

## Customization

Feel free to modify these files to match your preferences:
- `settings.json`: General VS Code settings
- `keybindings.json`: Custom keyboard shortcuts
- `extensions.json`: Recommended extensions list
# Partial-file management

Read this file when chezmoi must not own the whole target file.
Pick a pattern by who owns the file.

## `modify_` — the user owns the file, chezmoi stamps a block

A `modify_` source is a script by default.
It reads the current target on stdin and writes the new target to stdout.
Use the script form when you need a real interpreter (`jq`, `awk`, `sed`).

Script form, `modify_dot_zshrc`:

```bash
#!/usr/bin/env bash
set -euo pipefail
# Strip any prior chezmoi block from the existing file …
awk '/# chezmoi:begin/{s=1;next} /# chezmoi:end/{s=0;next} !s'
# … then append the current managed block.
cat <<'EOF'

# chezmoi:begin
export EDITOR=nvim
alias g=git
# chezmoi:end
EOF
```

When the file contains the string `chezmoi:modify-template`, chezmoi strips the marker lines.
It then renders the rest as a template, with the existing target in `.chezmoi.stdin`.
Use the template form to edit a structured file (JSON, TOML, YAML).
Modify templates must not carry a `.tmpl` suffix; the suffix triggers a separate template pass that breaks the `.chezmoi.stdin` round-trip.

Template form, `modify_dot_config_private_app.yaml`:

```go-template
{{- /* chezmoi:modify-template */ -}}
{{- $cfg := dict -}}
{{- if .chezmoi.stdin -}}{{- $cfg = .chezmoi.stdin | fromYaml -}}{{- end -}}
{{- $_ := set $cfg "telemetry" false -}}
{{- $_ := set $cfg "user" (dict "email" .email) -}}
{{ toYaml $cfg }}
```

The `if .chezmoi.stdin` guard handles the first apply, when the target does not exist yet.
Use `fromJsonc` / `fromToml` / `fromYaml` with `toPrettyJson` / `toToml` / `toYaml` for the round-trip.

## `.chezmoitemplates/` — chezmoi owns the file, fragments are shared

Reusable blocks live under `.chezmoitemplates/`.
Pull them into regular templates with `{{ template "name" . }}`.
Use `includeTemplate "name" .` when you must pipe the result through a function.

```text
.chezmoitemplates/zsh-prompt          # one file
dot_zshrc.tmpl                        # {{ template "zsh-prompt" . }}
dot_config/fish/config.fish.tmpl      # {{ template "zsh-prompt" . }} too
```

## Choose by ownership

Use `modify_` when the user can freely edit the file outside the managed block.
Use `.chezmoitemplates/` when chezmoi renders the whole file and only shares sections.
Mixing both in one target is usually a smell.

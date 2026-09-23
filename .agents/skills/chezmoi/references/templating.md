# Templating

chezmoi uses Go's `text/template`. A source file with a `.tmpl` suffix is
rendered and written to its target path in `~`. Files under
`.chezmoitemplates/` are *reusable fragments* — they are included by other
templates via `{{ template "name" . }}` and do **not** produce target files
themselves.

## Built-in variables

Always available inside any template:

| Variable | Example | Meaning |
|---|---|---|
| `.chezmoi.os` | `darwin`, `linux`, `windows` | GOOS of the current machine |
| `.chezmoi.arch` | `amd64`, `arm64` | GOARCH |
| `.chezmoi.hostname` | `mbp-2024` | Short hostname |
| `.chezmoi.fqdnHostname` | `mbp-2024.local` | Fully qualified |
| `.chezmoi.username` | `paul` | Current user |
| `.chezmoi.homeDir` | `/Users/paul` | Target home |
| `.chezmoi.sourceDir` | `~/.local/share/chezmoi` | Source root |
| `.chezmoi.osRelease` (linux) | `{ID: "ubuntu", VERSION_ID: "24.04"}` | Parsed `/etc/os-release` |
| `.chezmoi.kernel` | `Linux 6.5.0-...` | uname output |

User-defined data is reachable as plain dotted keys: if `chezmoi.toml`
has `[data] email = "x@y.z"`, then `{{ .email }}` renders `x@y.z`.

## Conditionals

```go-template
{{- if eq .chezmoi.os "darwin" }}
# macOS only
{{- else if eq .chezmoi.os "linux" }}
# Linux only
{{- end }}

{{- if and (eq .chezmoi.os "darwin") (.work) }}
# work Mac only
{{- end }}

{{- if or (.personal) (.use_secrets) }}
# personal OR secrets enabled
{{- end }}

{{- if not (eq .chezmoi.hostname "headless-vm") }}
# everywhere except the headless VM
{{- end }}
```

## Useful template functions (chezmoi-specific)

| Function | Purpose |
|---|---|
| `lookPath "brew"` | Return absolute path to executable, empty string if missing — perfect for "is X installed" |
| `output "git" "config" "user.name"` | Run a command at template time, return stdout (use sparingly) |
| `glob "~/.config/*"` | Return matching paths |
| `joinPath`, `quote`, `replace`, `trim` | Standard text helpers |
| `include "name.tmpl"` | Inline another template fragment from `.chezmoitemplates/` |
| `stat "/path"` | Return file info or empty string — useful for "if file exists" |

## Prompt functions (config-template only)

These are *only* valid inside `.chezmoi.toml.tmpl` (or `.yaml.tmpl` /
`.json.tmpl`). Using them in a regular dotfile template causes a prompt
on every `chezmoi apply` / `diff` / `status`.

| Function | Use when |
|---|---|
| `promptStringOnce . "email" "Email address"` | One-time string prompt, persisted |
| `promptBoolOnce . "work" "Is this a work machine?"` | One-time bool prompt |
| `promptIntOnce . "screen_width" "Screen width"` | One-time int prompt |
| `promptString` / `promptBool` / `promptInt` | Prompt every init (rare) |
| `promptChoiceOnce` | Constrained choice |

The `Once` suffix makes chezmoi store the answer in the rendered config
so it doesn't re-prompt.

## .chezmoidata/

Files under `.chezmoidata/` are merged into the top-level template
namespace. Supported formats: `*.toml`, `*.yaml`, `*.json`, `*.jsonc`.
Files don't have to be checked in — they just need to exist when
`chezmoi apply` runs. This is perfect for non-secret machine data and
for cached secret bundles.

```yaml
# .chezmoidata/work.yaml
work:
  email: paul@company.com
  vpn:
    server: vpn.company.com
```

Then in any template: `{{ .work.email }}` → `paul@company.com`.

## .chezmoitemplates/

Holds reusable template fragments. Reference them via
`{{ template "name" . }}`:

```text
.chezmoitemplates/
└── ssh-prelude
```

```go-template
{{ template "ssh-prelude" . }}
Host github.com
  User git
```

## .chezmoiignore (templatable)

Matches *source-relative* paths. Itself a template — ignore
platform-specific files when on the wrong platform:

```go-template
README.md
LICENSE

{{- if ne .chezmoi.os "darwin" }}
Library/Application Support/Code/User/settings.json
{{- end }}

{{- if .headless }}
private_dot_config/window-manager
{{- end }}
```

## Iterating over data

```toml
# .chezmoidata/servers.toml
[servers.alpha]
ip = "10.0.0.1"
include = true

[servers.beta]
ip = "10.0.0.2"
include = false
```

```go-template
{{ range $name, $cfg := .servers -}}
{{- if $cfg.include }}
Host {{ $name }}
  HostName {{ $cfg.ip }}
{{- end }}
{{- end }}
```

Inside `range`, `.` rebinds to the current item — use `$.` to reach the
outer scope.

## Debugging templates

```bash
chezmoi execute-template < file.tmpl     # render against current data
chezmoi execute-template '{{ .chezmoi.os }}'
chezmoi data                             # dump the entire template namespace
```

`chezmoi execute-template` is the canonical "what would this render to"
debugger — use it whenever a template doesn't behave.

## Missing keys and empty renders

chezmoi runs templates with Go's `missingkey=error` option.
A typo such as `{{ .gitub.user }}` fails the apply instead of rendering empty.
Set `[template] options = ["missingkey=zero"]` only for a concrete reason; you lose the typo guard.

For a symlink target, chezmoi strips leading and trailing whitespace from the render.
An empty render removes the symlink.
For a file target, an empty render removes the file. Use the `empty_` prefix to keep it.

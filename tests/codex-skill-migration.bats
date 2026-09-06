#!/usr/bin/env bats
# Regression tests for migration of proven legacy Codex skill duplicates.

load test_helper

setup() {
    setup_test_env
    export LEGACY="$TEST_HOME/.codex/skills"
    export CANONICAL="$TEST_HOME/.agents/skills"
    export ARCHIVE="$TEST_HOME/.local/state/dotfiles/codex-skills-legacy"
    export REGISTRY="$TEST_HOME/skills-registry.yaml"
    mkdir -p "$LEGACY" "$CANONICAL"
    cat > "$REGISTRY" <<'YAML'
sources:
  paulnsorensen/easy-cheese:
    description: fixture
YAML
}

teardown() { teardown_test_env; }

write_managed_skill() {
    local root="$1" name="$2" body="$3" repo="${4:-paulnsorensen/easy-cheese}"
    local skill_path="${5:-skills/$name}"
    mkdir -p "$root/$name"
    cat > "$root/$name/SKILL.md" <<EOF
---
name: $name
github-repo: https://github.com/$repo
github-ref: refs/tags/v0.5.3
github-path: $skill_path
github-tree-sha: deadbeef
---
$body
EOF
}

run_migration() {
    run bash "$REAL_DOTFILES_DIR/chezmoi/lib/migrate-codex-skill-duplicates.sh" \
        "$LEGACY" "$CANONICAL" "$ARCHIVE" "$REGISTRY"
}

@test "managed duplicate archives the legacy tree and keeps canonical skill" {
    write_managed_skill "$LEGACY" age "legacy"
    write_managed_skill "$CANONICAL" age "canonical"

    run_migration

    assert_success
    [ ! -e "$LEGACY/age" ]
    [ -f "$CANONICAL/age/SKILL.md" ]
    run find "$ARCHIVE" -type f -name SKILL.md
    assert_success
    [ "$output" = "$ARCHIVE/age/SKILL.md" ]
    run grep -F "legacy" "$ARCHIVE/age/SKILL.md"
    assert_success
}

@test "metadata-free canonical archives with matching skills lock provenance" {
    write_managed_skill "$LEGACY" age "legacy"
    mkdir -p "$CANONICAL/age" "$TEST_HOME/.agents"
    printf '# canonical\n' > "$CANONICAL/age/SKILL.md"
    cat > "$TEST_HOME/.agents/.skill-lock.json" <<'JSON'
{
  "version": 3,
  "skills": {
    "age": {
      "source": "paulnsorensen/easy-cheese",
      "sourceType": "github",
      "sourceUrl": "https://github.com/paulnsorensen/easy-cheese.git",
      "skillPath": "skills/age/SKILL.md",
      "skillFolderHash": "c08de021c2ee1a4e5b381f0e7f23dc52406e29"
    }
  }
}
JSON

    run_migration

    assert_success
    [ ! -d "$LEGACY/age" ]
    [ -f "$ARCHIVE/age/SKILL.md" ]
}

@test "metadata-free canonical remains without a skills lock manifest" {
    write_managed_skill "$LEGACY" age "legacy"
    mkdir -p "$CANONICAL/age"
    printf '# canonical\n' > "$CANONICAL/age/SKILL.md"

    run_migration

    assert_success
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}

@test "metadata-free canonical remains with unmatched skills lock provenance" {
    write_managed_skill "$LEGACY" age "legacy"
    mkdir -p "$CANONICAL/age" "$TEST_HOME/.agents"
    printf '# canonical\n' > "$CANONICAL/age/SKILL.md"
    printf '%s\n' '{"version":3,"skills":{"age":{"source":"other/source","skillPath":"skills/age/SKILL.md"}}}' > "$TEST_HOME/.agents/.skill-lock.json"

    run_migration

    assert_success
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}

@test "metadata-free canonical remains with a version 2 skills lock manifest" {
    write_managed_skill "$LEGACY" age "legacy"
    mkdir -p "$CANONICAL/age" "$TEST_HOME/.agents"
    printf '# canonical\n' > "$CANONICAL/age/SKILL.md"
    cat > "$TEST_HOME/.agents/.skill-lock.json" <<'JSON'
{
  "version": 2,
  "skills": {
    "age": {
      "source": "paulnsorensen/easy-cheese",
      "sourceType": "github",
      "sourceUrl": "https://github.com/paulnsorensen/easy-cheese.git",
      "skillPath": "skills/age/SKILL.md"
    }
  }
}
JSON

    run_migration

    assert_success
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}

@test "metadata-free canonical remains with an unsupported skills lock path" {
    write_managed_skill "$LEGACY" age "legacy"
    mkdir -p "$CANONICAL/age" "$TEST_HOME/.agents"
    printf '# canonical\n' > "$CANONICAL/age/SKILL.md"
    cat > "$TEST_HOME/.agents/.skill-lock.json" <<'JSON'
{
  "version": 3,
  "skills": {
    "age": {
      "source": "paulnsorensen/easy-cheese",
      "sourceType": "github",
      "sourceUrl": "https://github.com/paulnsorensen/easy-cheese.git",
      "skillPath": "vendor/age/SKILL.md"
    }
  }
}
JSON

    run_migration

    assert_success
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}

@test "archive containment resolves dot-dot before comparing roots" {
    write_managed_skill "$LEGACY" age "legacy"
    write_managed_skill "$CANONICAL" age "canonical"

    run bash "$REAL_DOTFILES_DIR/chezmoi/lib/migrate-codex-skill-duplicates.sh" \
        "$LEGACY" "$CANONICAL" "$LEGACY/../skills" "$REGISTRY"

    assert_failure
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}

@test "standard macOS TMPDIR archive path is accepted after normalization" {
    write_managed_skill "$LEGACY" age "legacy"
    write_managed_skill "$CANONICAL" age "canonical"

    run_migration

    assert_success
    [ ! -d "$LEGACY/age" ]
    [ -f "$ARCHIVE/age/SKILL.md" ]
}

@test "metadata-free canonical accepts the .agents skills lock path" {
    write_managed_skill "$LEGACY" age "legacy" paulnsorensen/easy-cheese ".agents/skills/age"
    mkdir -p "$CANONICAL/age" "$TEST_HOME/.agents"
    printf '# canonical\n' > "$CANONICAL/age/SKILL.md"
    cat > "$TEST_HOME/.agents/.skill-lock.json" <<'JSON'
{
  "version": 3,
  "skills": {
    "age": {
      "source": "paulnsorensen/easy-cheese",
      "sourceType": "github",
      "sourceUrl": "https://github.com/paulnsorensen/easy-cheese.git",
      "skillPath": ".agents/skills/age/SKILL.md"
    }
  }
}
JSON

    run_migration

    assert_success
    [ ! -d "$LEGACY/age" ]
    [ -f "$ARCHIVE/age/SKILL.md" ]
}

@test "archive dot-dot path through a nonexistent component stays outside discovery roots" {
    write_managed_skill "$LEGACY" age "legacy"
    write_managed_skill "$CANONICAL" age "canonical"

    run bash "$REAL_DOTFILES_DIR/chezmoi/lib/migrate-codex-skill-duplicates.sh" \
        "$LEGACY" "$CANONICAL" "$TEST_HOME/new-parent/../.codex/skills/archive" "$REGISTRY"

    assert_failure
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}

@test "safe symlinked home ancestor resolves to an external archive" {
    local home_link="$TEST_HOME/home-link"
    ln -s "$TEST_HOME" "$home_link"
    mkdir -p "$home_link/.codex/skills" "$home_link/.agents/skills"

    write_managed_skill "$home_link/.codex/skills" age "legacy"
    write_managed_skill "$home_link/.agents/skills" age "canonical"

    run bash "$REAL_DOTFILES_DIR/chezmoi/lib/migrate-codex-skill-duplicates.sh" \
        "$home_link/.codex/skills" "$home_link/.agents/skills" \
        "$home_link/.local/state/dotfiles/codex-skills-legacy" "$REGISTRY"

    assert_success
    [ ! -d "$home_link/.codex/skills/age" ]
    [ -f "$home_link/.local/state/dotfiles/codex-skills-legacy/age/SKILL.md" ]
}

@test "archive symlink target inside discovery roots is rejected" {
    write_managed_skill "$LEGACY" age "legacy"
    write_managed_skill "$CANONICAL" age "canonical"
    ln -s "$LEGACY" "$TEST_HOME/archive-link"

    run bash "$REAL_DOTFILES_DIR/chezmoi/lib/migrate-codex-skill-duplicates.sh" \
        "$LEGACY" "$CANONICAL" "$TEST_HOME/archive-link" "$REGISTRY"

    assert_failure
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}

@test "equal physical discovery roots are rejected before migration" {
    local shared="$TEST_HOME/shared"
    rmdir "$TEST_HOME/.codex/skills" "$TEST_HOME/.codex"
    mkdir -p "$shared/.agents/skills"
    ln -s "$shared/.agents" "$TEST_HOME/.codex"
    write_managed_skill "$shared/.agents/skills" age "canonical"

    run bash "$REAL_DOTFILES_DIR/chezmoi/lib/migrate-codex-skill-duplicates.sh" \
        "$TEST_HOME/.codex/skills" "$shared/.agents/skills" "$ARCHIVE" "$REGISTRY"

    assert_failure
    [ -f "$shared/.agents/skills/age/SKILL.md" ]
    run grep -F "canonical" "$shared/.agents/skills/age/SKILL.md"
    assert_success
    [ ! -e "$ARCHIVE" ]
}

@test "legacy ancestor discovery root is rejected before migration" {
    local legacy_root="$TEST_HOME/legacy-root"
    local canonical_root="$legacy_root/canonical"
    mkdir -p "$legacy_root" "$canonical_root"
    write_managed_skill "$legacy_root" age "legacy"
    write_managed_skill "$canonical_root" age "canonical"

    run bash "$REAL_DOTFILES_DIR/chezmoi/lib/migrate-codex-skill-duplicates.sh" \
        "$legacy_root" "$canonical_root" "$ARCHIVE" "$REGISTRY"

    assert_failure
    [ -f "$canonical_root/age/SKILL.md" ]
    run grep -F "canonical" "$canonical_root/age/SKILL.md"
    assert_success
    [ ! -e "$ARCHIVE" ]
}

@test "canonical ancestor discovery root is rejected before migration" {
    local canonical_root="$TEST_HOME/canonical-root"
    local legacy_root="$canonical_root/legacy"
    mkdir -p "$legacy_root" "$canonical_root"
    write_managed_skill "$canonical_root" age "canonical"
    write_managed_skill "$legacy_root" age "legacy"

    run bash "$REAL_DOTFILES_DIR/chezmoi/lib/migrate-codex-skill-duplicates.sh" \
        "$legacy_root" "$canonical_root" "$ARCHIVE" "$REGISTRY"

    assert_failure
    [ -f "$canonical_root/age/SKILL.md" ]
    run grep -F "canonical" "$canonical_root/age/SKILL.md"
    assert_success
    [ ! -e "$ARCHIVE" ]
}

@test "metadata-free canonical remains with malformed skills lock manifest" {
    write_managed_skill "$LEGACY" age "legacy"
    mkdir -p "$CANONICAL/age" "$TEST_HOME/.agents"
    printf '# canonical\n' > "$CANONICAL/age/SKILL.md"
    printf '%s\n' '{not-json' > "$TEST_HOME/.agents/.skill-lock.json"

    run_migration

    assert_success
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}

@test "unknown local skill remains even when canonical name matches" {
    mkdir -p "$LEGACY/local-only" "$CANONICAL/local-only"
    printf '# local\n' > "$LEGACY/local-only/SKILL.md"
    printf '# canonical\n' > "$CANONICAL/local-only/SKILL.md"

    run_migration

    assert_success
    [ -d "$LEGACY/local-only" ]
    [ ! -d "$ARCHIVE/local-only" ]
}

@test "managed duplicate remains when canonical counterpart is absent" {
    write_managed_skill "$LEGACY" age "legacy"

    run_migration

    assert_success
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}

@test "missing roots are a safe no-op" {
    rm -rf "$LEGACY" "$CANONICAL"

    run_migration

    assert_success
    [ ! -e "$ARCHIVE" ]
}

@test ".system remains untouched" {
    write_managed_skill "$LEGACY" .system "system"
    write_managed_skill "$CANONICAL" .system "system"

    run_migration

    assert_success
    [ -d "$LEGACY/.system" ]
    [ ! -e "$ARCHIVE/.system" ]
}

@test "second run does not create another archive" {
    write_managed_skill "$LEGACY" age "legacy"
    write_managed_skill "$CANONICAL" age "canonical"

    run_migration
    assert_success
    run find "$ARCHIVE" -mindepth 1 -maxdepth 1 -type d
    assert_success
    first_archive_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
    [ "$first_archive_count" -eq 1 ]

    run_migration
    assert_success
    run find "$ARCHIVE" -mindepth 1 -maxdepth 1 -type d
    assert_success
    second_archive_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
    [ "$second_archive_count" -eq 1 ]
}

@test "symlinked legacy skill and archive-inside-root stay untouched" {
    mkdir -p "$TEST_HOME/outside/escape" "$CANONICAL/escape"
    printf '# outside\n' > "$TEST_HOME/outside/escape/SKILL.md"
    ln -s "$TEST_HOME/outside/escape" "$LEGACY/escape"
    mkdir -p "$LEGACY/archive-target"
    write_managed_skill "$LEGACY" age "legacy"
    write_managed_skill "$CANONICAL" age "canonical"

    run bash "$REAL_DOTFILES_DIR/chezmoi/lib/migrate-codex-skill-duplicates.sh" \
        "$LEGACY" "$CANONICAL" "$LEGACY/archive-target" "$REGISTRY"

    assert_failure
    [ -L "$LEGACY/escape" ]
    [ -d "$LEGACY/age" ]
}

@test "canonical symlink target does not become migration evidence" {
    write_managed_skill "$LEGACY" age "legacy"
    mkdir -p "$TEST_HOME/outside/canonical-age"
    write_managed_skill "$TEST_HOME/outside" canonical-age "canonical"
    ln -s "$TEST_HOME/outside/canonical-age" "$CANONICAL/age"

    run_migration

    assert_success
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}


@test "identical trees without metadata are accepted as a legacy duplicate" {
    mkdir -p "$LEGACY/old-skill" "$CANONICAL/old-skill"
    printf '# same\n' > "$LEGACY/old-skill/SKILL.md"
    printf '# same\n' > "$CANONICAL/old-skill/SKILL.md"

    run_migration

    assert_success
    [ ! -d "$LEGACY/old-skill" ]
    [ -f "$ARCHIVE/old-skill/SKILL.md" ]
}



@test "plugin roots remain untouched" {
    mkdir -p "$LEGACY/native-plugin/.claude-plugin" "$CANONICAL/native-plugin/.claude-plugin"
    printf '# plugin\\n' > "$LEGACY/native-plugin/SKILL.md"
    printf '# plugin\\n' > "$CANONICAL/native-plugin/SKILL.md"
    printf '{}\\n' > "$LEGACY/native-plugin/.claude-plugin/marketplace.json"

    run_migration

    assert_success
    [ -d "$LEGACY/native-plugin" ]
    [ ! -e "$ARCHIVE/native-plugin" ]
}


@test "ineligible Claude-only source does not archive a same-name legacy skill" {
    cat > "$REGISTRY" <<'YAML'
sources:
  paulnsorensen/easy-cheese:
    harnesses: [claude]
YAML
    write_managed_skill "$LEGACY" age "legacy"
    write_managed_skill "$CANONICAL" age "canonical"

    run_migration

    assert_success
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}

@test "canonical metadata must match the legacy source" {
    cat >> "$REGISTRY" <<'YAML'
  acme/other-source:
    description: unrelated source
YAML
    write_managed_skill "$LEGACY" age "legacy"
    write_managed_skill "$CANONICAL" age "canonical" acme/other-source

    run_migration

    assert_success
    [ -d "$LEGACY/age" ]
    [ ! -e "$ARCHIVE/age" ]
}

@test "dots sync runs migration after the installer refreshes shared skills" {
    local stub="$TEST_HOME/ordering-dotfiles"
    mkdir -p "$stub/bin" "$stub/chezmoi/lib" "$stub/skills"
    cp "$REAL_DOTFILES_DIR/bin/dots" "$stub/bin/dots"
    : > "$stub/skills/_registry.yaml"

    cat > "$stub/.sync" <<'SH'
#!/bin/bash
echo sync
SH
    cat > "$stub/chezmoi/lib/install-external.sh" <<'SH'
#!/bin/bash
mkdir -p "$HOME/.agents/skills"
printf 'ready\n' > "$HOME/.agents/skills/ready"
echo installer
SH
    cat > "$stub/chezmoi/lib/migrate-codex-skill-duplicates.sh" <<'SH'
#!/bin/bash
if [[ ! -f "$HOME/.agents/skills/ready" ]]; then
    echo migration-before-installer >&2
    exit 41
fi
echo migration
SH
    chmod +x "$stub/bin/dots" "$stub/.sync" \
        "$stub/chezmoi/lib/install-external.sh" \
        "$stub/chezmoi/lib/migrate-codex-skill-duplicates.sh"

    DOTFILES_DIR="$stub" PATH="$stub/bin:$PATH" run "$stub/bin/dots" sync

    assert_success
    assert_output_contains "installer"
    assert_output_contains "migration"
    local installer_line migration_line
    installer_line=$(printf '%s\n' "$output" | awk '/installer/ { print NR; exit }')
    migration_line=$(printf '%s\n' "$output" | awk '/migration$/ { print NR; exit }')
    [ "$installer_line" -lt "$migration_line" ]
}

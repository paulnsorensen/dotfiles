# Ruby Justfile Recipes

## Template (Rails)

```just
set dotenv-load := true

default:
    @just --list

# Install dependencies
install:
    bundle install

# Run dev server
dev:
    bin/rails server

# Open Rails console
console:
    bin/rails console

# Run tests (coverage enforced via SimpleCov in spec_helper.rb)
test *args:
    bundle exec rspec {{args}}

# Lint
lint:
    bundle exec rubocop

# Lint and auto-fix
lint-fix:
    bundle exec rubocop -a

# Database tasks
db-migrate:
    bin/rails db:migrate

db-rollback:
    bin/rails db:rollback

db-seed:
    bin/rails db:seed

db-reset:
    bin/rails db:drop db:create db:migrate db:seed

# Show routes
routes:
    bin/rails routes
```

## Template (gem/library)

```just
default: check

check: lint test

test *args:
    bundle exec rspec {{args}}

lint:
    bundle exec rubocop

fmt:
    bundle exec rubocop -a

build:
    gem build *.gemspec

install-local: build
    gem install *.gem
```

## Coverage config (spec/spec_helper.rb)

SimpleCov has the **strongest native per-file support** of any ecosystem here — use it.

```ruby
require 'simplecov'

SimpleCov.start do
  add_filter '/spec/'

  # Native per-file floor — fails if ANY file drops below this
  minimum_coverage_by_file 80

  # Global floor
  minimum_coverage line: 90, branch: 85

  # Ratchet: read committed high-water mark, auto-raise on improvement
  threshold = File.exist?('.coverage_threshold') \
    ? File.read('.coverage_threshold').strip.to_f \
    : 85.0
  minimum_coverage line: [threshold, 90].max

  at_exit do
    pct = SimpleCov.result&.covered_percent || 0
    File.write('.coverage_threshold', pct.round(2).to_s) if pct > threshold
  end
end
```

Commit `.coverage_threshold` to enforce the ratchet in CI. Real-world floors: omniauth=92.5, pagy=100, ViewComponent=100.

## Notes

- Use `bin/rails` (binstub) not `rails` or `bundle exec rails`
- For non-Rails Ruby apps, drop the Rails-specific recipes
- If using Minitest instead of RSpec, adjust test command
- For Sorbet, add `typecheck: bundle exec srb tc`

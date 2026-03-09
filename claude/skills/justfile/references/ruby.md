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

# Run tests
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

## Notes

- Use `bin/rails` (binstub) not `rails` or `bundle exec rails`
- For non-Rails Ruby apps, drop the Rails-specific recipes
- If using Minitest instead of RSpec, adjust test command
- For Sorbet, add `typecheck: bundle exec srb tc`

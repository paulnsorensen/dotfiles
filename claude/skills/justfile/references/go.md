# Go Justfile Recipes

## Template

```just
set dotenv-load := true

BINARY := "myapp"
VERSION := `git describe --tags --always 2>/dev/null || echo "dev"`

default: check

# Run all checks
check: lint test

# Build binary
build:
    go build -ldflags "-X main.version={{VERSION}}" -o bin/{{BINARY}} ./cmd/{{BINARY}}

# Run the app
run *args:
    go run ./cmd/{{BINARY}} {{args}}

# Run tests
test *args:
    go test ./... {{args}}

# Run tests with race detector
test-race:
    go test -race ./...

# Run tests with coverage report
test-coverage:
    go test -coverprofile=coverage.out -covermode=atomic ./...
    go tool cover -html=coverage.out

# Enforce global coverage threshold (Go has no native --fail-under)
cov-check MIN="80":
    go test -coverprofile=coverage.out -covermode=atomic ./...
    go tool cover -func=coverage.out | tail -1 | \
        awk -v min={{MIN}} '{gsub(/%/,"",$3); if ($3+0 < min) {printf "FAIL: %s%% < %s%%\n", $3, min; exit 1}}'

# Per-package coverage gate
cov-per-package MIN="75":
    go test -coverprofile=coverage.out ./...
    go tool cover -func=coverage.out | awk -v min={{MIN}} '
        /^total:/ {next}
        {gsub(/%/,"",$NF); if ($NF+0 < min) { printf "FAIL %s: %s%%\n",$1,$NF; bad=1 }}
        END { exit bad+0 }'

# Ratchet: never let overall coverage regress (reads/writes .coverage-baseline)
cov-ratchet:
    #!/usr/bin/env bash
    go test -coverprofile=coverage.out ./... >/dev/null
    CUR=$(go tool cover -func=coverage.out | tail -1 | awk '{gsub(/%/,"",$3); print $3}')
    BASE=$(cat .coverage-baseline 2>/dev/null || echo 0)
    awk -v c=$CUR -v b=$BASE 'BEGIN{exit !(c>=b)}' \
        && echo $CUR > .coverage-baseline \
        || { echo "Coverage regression: $CUR% < $BASE%"; exit 1; }

# Lint (requires golangci-lint)
lint:
    golangci-lint run ./...

# Format
fmt:
    gofmt -s -w .
    goimports -w .

# Tidy modules
tidy:
    go mod tidy

# Generate code
generate:
    go generate ./...

# Clean
clean:
    rm -rf bin/ coverage.out
```

## Cross-compilation

```just
build-all:
    GOOS=linux GOARCH=amd64 go build -o bin/{{BINARY}}-linux-amd64 ./cmd/{{BINARY}}
    GOOS=darwin GOARCH=arm64 go build -o bin/{{BINARY}}-darwin-arm64 ./cmd/{{BINARY}}
    GOOS=windows GOARCH=amd64 go build -o bin/{{BINARY}}-windows-amd64.exe ./cmd/{{BINARY}}
```

## Coverage notes

- Go's toolchain has no `--fail-under` flag — thresholds always require a shell script or awk one-liner.
- The awk pattern above is the OSS idiom; some projects use env-var `COVERAGE_THRESHOLD` instead of a just parameter.
- Commit `.coverage-baseline` to enforce the ratchet in CI.

## Notes

- Replace `myapp` and `./cmd/myapp` with actual binary/module path
- If no `cmd/` directory, use `./` or `.` as the build path
- Check for `golangci-lint` config (`.golangci.yml`) before adding lint recipe
- For web services, add `dev` recipe with air/reflex for hot reload
- For protobuf projects, add `proto` recipe for code generation

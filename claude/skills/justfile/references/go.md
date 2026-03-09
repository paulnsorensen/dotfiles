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

# Run tests with coverage
test-coverage:
    go test -coverprofile=coverage.out ./...
    go tool cover -html=coverage.out

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

## Notes

- Replace `myapp` and `./cmd/myapp` with actual binary/module path
- If no `cmd/` directory, use `./` or `.` as the build path
- Check for `golangci-lint` config (`.golangci.yml`) before adding lint recipe
- For web services, add `dev` recipe with air/reflex for hot reload
- For protobuf projects, add `proto` recipe for code generation

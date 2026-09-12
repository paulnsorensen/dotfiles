# Go local build, test, and check options

## Build and test cache

Do not set `GOCACHE=off`. Modern Go requires the build cache. Use an approved isolated cache directory for cold-build measurements. [Go 1.12 release notes](https://go.dev/doc/go1.12)

Use `go clean -cache` to clear build artifacts. Use `go clean -testcache` to clear cached test results. Use `go test -count=1` to bypass test result reuse for one run. These actions target different caches and have different effects. [Go build and test caching](https://pkg.go.dev/cmd/go#hdr-Build_and_test_caching)

## Parallelism flags

Use `go build -p N` to limit concurrent build commands. Use `go test -parallel N` to limit parallel test functions within each package. Keep these controls separate. Do not rely on a version-specific default. [Go build flags](https://pkg.go.dev/cmd/go#hdr-Build_and_test_flags) [Go test flags](https://pkg.go.dev/cmd/go#hdr-testing_flags)

## Race coverage

The race detector adds coverage for executed paths. Preserve `-race` in the project gate when it is required. Confirm platform support before use. [Go race detector](https://go.dev/doc/articles/race_detector)

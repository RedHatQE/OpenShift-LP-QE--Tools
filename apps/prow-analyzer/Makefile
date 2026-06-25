# Local development Makefile for Go binaries
# For container builds, see image/container/prow-analyzer/Makefile
.PHONY: test test-coverage build build-cli build-bot clean help

# Build both binaries
build: build-cli build-bot

# Build CLI
build-cli:
	go build -o prow-analyzer--cli ./cmd/prow-analyzer--cli

# Build Bot
build-bot:
	go build -o prow-analyzer--bot ./cmd/prow-analyzer--bot

# Run tests
test:
	go test -v -race ./...

# Run tests with coverage and enforce threshold
test-coverage:
	./scripts/test-coverage.sh

# Clean build artifacts
clean:
	rm -f prow-analyzer--cli prow-analyzer--bot; \
	rm -f coverage.out coverage.html

# Help
help:
	@printf '%s\n' \
		'Prow Analyzer - Available targets:' \
		'  build         - Build both CLI and Bot binaries.' \
		'  build-cli     - Build CLI binary only.' \
		'  build-bot     - Build Bot binary only.' \
		'  test          - Run unit tests with race detector.' \
		'  test-coverage - Run tests with coverage.' \
		'  clean         - Remove build artifacts and coverage reports.'

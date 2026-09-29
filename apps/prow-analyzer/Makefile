# Local development Makefile for Go binaries
# For container builds, see image/container/prow-analyzer/Makefile
#
# Mirrors the CI contract in .github/workflows/prow-analyzer--build.yaml:
#   unit        -> go test -tags unit ...              (deterministic, all deps mocked)
#   integration -> go test -tags integration -race ... (real servers + async Handle path)
#   coverage    -> unit suite, -covermode=set, 100% gate
# Each tagged target first verifies the build tag actually selects tests, so a
# missing or misspelled //go:build line cannot silently pass with zero tests.
.PHONY: build build-cli build-bot test unit integration coverage test-coverage check-tags clean help

GO      ?= go
PKGS    ?= ./pkg/...
SCRIPTS := ./scripts

# Build both binaries
build: build-cli build-bot

# Build CLI
build-cli:
	$(GO) build -o prow-analyzer--cli ./cmd/prow-analyzer--cli

# Build Bot
build-bot:
	$(GO) build -o prow-analyzer--bot ./cmd/prow-analyzer--bot

# Run the full suite: unit then integration (mirrors CI ordering)
test: unit integration

# Unit tests: exactly the CI unit contract (all deps mocked, no goroutines, no race)
unit:
	$(SCRIPTS)/require-tagged-tests.sh unit $(PKGS)
	$(GO) test -v -tags unit $(PKGS)

# Integration tests: real HTTP servers and the async Handle() path, under -race
integration:
	$(SCRIPTS)/require-tagged-tests.sh integration $(PKGS)
	$(GO) test -v -tags integration -race $(PKGS)

# Coverage against the unit suite with the 100% gate (mirrors CI). Alias: coverage
coverage test-coverage:
	$(SCRIPTS)/test-coverage.sh

# Fail if either build tag selects no tests (guards against silent 0-test runs)
check-tags:
	$(SCRIPTS)/require-tagged-tests.sh unit $(PKGS)
	$(SCRIPTS)/require-tagged-tests.sh integration $(PKGS)

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
		'  unit          - Run unit tests (-tags unit).' \
		'  integration   - Run integration tests (-tags integration -race).' \
		'  test          - Run unit then integration tests.' \
		'  coverage      - Unit coverage with 100% gate (alias: test-coverage).' \
		'  check-tags    - Fail if a build tag selects no tests.' \
		'  clean         - Remove build artifacts and coverage reports.'

# Local and GitHub Actions entry points for application builds and tests.
# For container builds, see image/container/prow-analyzer/Makefile.
.PHONY: build build--cli build--bot test test--unit test--integration check-tags clean help

SHELL   := /bin/bash
GO      ?= go
PKGS    ?= ./pkg/...
SCRIPTS := ./scripts

# Build both binaries
build: build--cli build--bot

# Build CLI
build--cli:
	$(GO) build -o prow-analyzer--cli ./cmd/prow-analyzer--cli

# Build Bot
build--bot:
	$(GO) build -o prow-analyzer--bot ./cmd/prow-analyzer--bot

# Run the full suite: unit (with coverage gate) then integration (mirrors CI ordering)
test: test--unit test--integration

# Gate ./pkg/... at 100% coverage and run bot command tests separately.
test--unit:
	$(SCRIPTS)/test-coverage.sh

# Integration tests: real HTTP servers and the async Handle() path, under -race.
test--integration:
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    $(SCRIPTS)/require-tagged-tests.sh integration $(PKGS);\
	    $(GO) test -v -tags integration -race $(PKGS);\
	}

# Fail if either build tag selects no tests (guards against silent 0-test runs)
check-tags:
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    $(SCRIPTS)/require-tagged-tests.sh unit $(PKGS);\
	    $(SCRIPTS)/require-tagged-tests.sh integration $(PKGS);\
	}

# Clean build artifacts
clean:
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    rm -f prow-analyzer--cli prow-analyzer--bot;\
	    rm -f coverage.out coverage.html;\
	}

# Help
help:
	@printf '%s\n' \
		'Prow Analyzer - Available targets:' \
		'  build             - Build both CLI and Bot binaries.' \
		'  build--cli        - Build CLI binary only.' \
		'  build--bot        - Build Bot binary only.' \
		'  test--unit        - Unit tests with embedded 100% coverage gate.' \
		'  test--integration - Integration tests (-tags integration -race).' \
		'  test              - Run unit then integration tests.' \
		'  check-tags        - Fail if a build tag selects no tests.' \
		'  clean             - Remove build artifacts and coverage reports.'

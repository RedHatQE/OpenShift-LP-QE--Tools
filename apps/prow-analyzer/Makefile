# Local development Makefile for Go binaries
# For container builds, see image/container/prow-analyzer/Makefile
#
# GitHub Actions invokes these same targets (see
# .github/workflows/prow-analyzer--build.yaml) so local and CI runs cannot
# diverge:
#   test--unit        -> unit suite with the embedded 100% coverage gate
#                        (all deps mocked, deterministic, no race)
#   test--integration -> integration suite under -race (real servers + async Handle)
# Our philosophy is that unit tests MUST reach 100% coverage, so the coverage
# gate lives inside test--unit rather than in a separate target.
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

# Unit tests with the embedded 100% coverage gate (single shell invocation via the
# shared script, which also guards that the unit build tag selects tests).
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

# Local and GitHub Actions entry points for application builds and tests.
# For container builds, see image/container/prow-analyzer/Makefile.
.PHONY: build build--cli build--bot test test--unit test--integration check-tags clean help

SHELL   := /bin/bash
GO      ?= go
PKGS    ?= ./pkg/...

# Parameters: build tag, whitespace-separated package patterns, minimum count.
# Capture listing failures before counting test/benchmark/fuzz/example names.
define require-tagged-tests
typeset buildTag='$(1)'; \
typeset -a pkgsArr; \
read -r -a pkgsArr <<< '$(strip $(2))'; \
typeset -i minCount='$(or $(3),1)'; \
: "Checking that -tags $${buildTag} selects at least $${minCount} test(s) in $(strip $(2))..."; \
typeset testList; \
testList=$$("$(GO)" test -tags "$${buildTag}" -list '.*' "$${pkgsArr[@]}"); \
typeset -i selected; \
selected=$$(printf '%s\n' "$${testList}" | awk '/^(Test|Benchmark|Fuzz|Example)/ {count++} END {print count+0}'); \
if (( selected < minCount )); then \
    : "❌ FAIL: -tags $${buildTag} selected $${selected} test(s) in $(strip $(2)) (expected >= $${minCount})."; \
    : "        A missing or misspelled //go:build $${buildTag} line yields 0 tests silently."; \
    exit 1; \
fi; \
: "✅ PASS: -tags $${buildTag} selected $${selected} test(s) in $(strip $(2))."
endef

# Build both binaries
build: build--cli build--bot

# Build CLI
build--cli:
	"$(GO)" build -o prow-analyzer--cli ./cmd/prow-analyzer--cli

# Build Bot
build--bot:
	"$(GO)" build -o prow-analyzer--bot ./cmd/prow-analyzer--bot

# Run the full suite: unit (with coverage gate) then integration (mirrors CI ordering)
test: test--unit test--integration

# Gate ./pkg/... at 100% coverage and run bot command tests separately.
test--unit:
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    typeset -r coverageThreshold=100.0;\
	    typeset -r coverageFile='coverage.out';\
	    typeset -r coverageHTML='coverage.html';\
	    : 'Guarding that the unit build tag actually selects tests...';\
	    $(call require-tagged-tests,unit,$(PKGS),1);\
	    : 'Running unit tests with coverage...';\
	    "$(GO)" test -v -tags unit -covermode=set -coverprofile="$${coverageFile}" "$${pkgsArr[@]}";\
	    : 'Generating coverage report...';\
	    "$(GO)" tool cover -html="$${coverageFile}" -o "$${coverageHTML}";\
	    : 'Calculating coverage percentage...';\
	    typeset coverageOutput;\
	    coverageOutput=$$("$(GO)" tool cover -func="$${coverageFile}");\
	    : "$${coverageOutput}";\
	    typeset totalCoverage;\
	    totalCoverage=$$(printf '%s\n' "$${coverageOutput}" | grep 'total:' | awk '{print $$3}' | sed 's/%//');\
	    : "Total coverage: $${totalCoverage}%";\
	    : "Required coverage: $${coverageThreshold}%";\
	    typeset isBelowThreshold;\
	    isBelowThreshold=$$(printf '%s\n' "$${totalCoverage} < $${coverageThreshold}" | bc -l);\
	    if (( isBelowThreshold )); then \
	        : "❌ FAIL: Coverage $${totalCoverage}% is below threshold $${coverageThreshold}%";\
	        : "Coverage report: $${coverageHTML}";\
	        exit 1;\
	    fi;\
	    : "✅ PASS: Coverage $${totalCoverage}% meets threshold $${coverageThreshold}%";\
	    : "Coverage report: $${coverageHTML}";\
	    : 'Guarding that the unit build tag selects bot tests...';\
	    $(call require-tagged-tests,unit,./cmd/prow-analyzer--bot,1);\
	    : 'Running bot env-consumer unit tests (outside the coverage gate)...';\
	    "$(GO)" test -v -tags unit "$${pkgsArr[@]}";\
	}

# Integration tests: real HTTP servers and the async Handle() path, under -race.
test--integration:
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    $(call require-tagged-tests,integration,$(PKGS),1);\
	    "$(GO)" test -v -tags integration -race "$${pkgsArr[@]}";\
	}

# Fail if either build tag selects no tests (guards against silent 0-test runs)
check-tags:
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    $(call require-tagged-tests,unit,$(PKGS),1);\
	    $(call require-tagged-tests,integration,$(PKGS),1);\
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

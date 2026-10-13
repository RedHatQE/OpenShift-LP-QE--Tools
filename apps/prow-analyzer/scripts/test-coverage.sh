#!/bin/bash
# test-coverage.sh — unit coverage gate, mirroring the CI "Unit Tests with
# Coverage" step in .github/workflows/prow-analyzer--build.yaml:
#     go test -tags unit -covermode=set -coverprofile=coverage.out ./pkg/...
#
# The unit suite mocks all external dependencies and spawns no goroutines, so it
# is deterministic without the race detector; covermode=set (per-statement) keeps
# the 100% gate reproducible. Integration tests (-tags integration -race) are run
# separately and are not part of the coverage number (see the Makefile).
#
# The bot command package (./cmd/prow-analyzer--bot) also carries unit tests for
# its environment consumers. They run here so `test--unit` covers them too, but
# outside the 100% gate: main() wires up Slack/MCP and is not unit-testable, so
# the package cannot reach 100% and is excluded from the coverage number.
set -euxo pipefail; shopt -s inherit_errexit

typeset scriptDir
scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scriptDir
typeset -r buildTag='unit'
typeset -r pkgs='./pkg/...'
typeset -r botPkg='./cmd/prow-analyzer--bot'
typeset -r coverageThreshold=100.0
typeset -r coverageFile='coverage.out'
typeset -r coverageHTML='coverage.html'

: 'Guarding that the unit build tag actually selects tests...'
"${scriptDir}/require-tagged-tests.sh" "${buildTag}" "${pkgs}"

: 'Running unit tests with coverage...'
go test -v -tags "${buildTag}" -covermode=set -coverprofile="${coverageFile}" "${pkgs}"

: 'Generating coverage report...'
go tool cover -html="${coverageFile}" -o "${coverageHTML}"

: 'Calculating coverage percentage...'
typeset coverageOutput
coverageOutput=$(go tool cover -func="${coverageFile}")

: "${coverageOutput}"

typeset totalCoverage
totalCoverage=$(echo "${coverageOutput}" | grep 'total:' | awk '{print $3}' | sed 's/%//')

: "Total coverage: ${totalCoverage}%"
: "Required coverage: ${coverageThreshold}%"

# Compare coverage (handle floating point)
if (( $(echo "${totalCoverage} < ${coverageThreshold}" | bc -l) )); then
    : "❌ FAIL: Coverage ${totalCoverage}% is below threshold ${coverageThreshold}%"
    : "Coverage report: ${coverageHTML}"
    exit 1
fi

: "✅ PASS: Coverage ${totalCoverage}% meets threshold ${coverageThreshold}%"
: "Coverage report: ${coverageHTML}"

: 'Guarding that the unit build tag selects bot tests...'
"${scriptDir}/require-tagged-tests.sh" "${buildTag}" "${botPkg}"

: 'Running bot env-consumer unit tests (outside the coverage gate)...'
go test -v -tags "${buildTag}" "${botPkg}"

true

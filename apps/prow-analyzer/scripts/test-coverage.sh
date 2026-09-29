#!/bin/bash
# test-coverage.sh — unit coverage gate, mirroring the CI "Unit Tests with
# Coverage" step in .github/workflows/prow-analyzer--build.yaml:
#     go test -tags unit -covermode=set -coverprofile=coverage.out ./pkg/...
#
# The unit suite mocks all external dependencies and spawns no goroutines, so it
# is deterministic without the race detector; covermode=set (per-statement) keeps
# the 100% gate reproducible. Integration tests (-tags integration -race) are run
# separately and are not part of the coverage number (see the Makefile).
set -euxo pipefail
# inherit_errexit needs bash >= 4.4 (CI); degrade gracefully on older bash (macOS 3.2)
shopt -s inherit_errexit 2>/dev/null || true

typeset scriptDir
scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scriptDir
typeset -r buildTag='unit'
typeset -r pkgs='./pkg/...'
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

true

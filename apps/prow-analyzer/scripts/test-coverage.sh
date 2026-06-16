#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset coverageThreshold=100.0
typeset coverageFile='coverage.out'
typeset coverageHTML='coverage.html'

: 'Running tests with coverage...'
# Use race detector if CGO is available, otherwise skip it
# Only test pkg/ directory (excludes cmd/main.go files)
if [[ "${CGO_ENABLED:-1}" == "1" ]] && command -v gcc &> /dev/null; then
    /usr/local/go/bin/go test -v -race -coverprofile="${coverageFile}" -covermode=atomic ./pkg/...
else
    : 'CGO not available, running without race detector'
    /usr/local/go/bin/go test -v -coverprofile="${coverageFile}" -covermode=atomic ./pkg/...
fi

: 'Generating coverage report...'
/usr/local/go/bin/go tool cover -html="${coverageFile}" -o "${coverageHTML}"

: 'Calculating coverage percentage...'
typeset coverageOutput
coverageOutput=$(/usr/local/go/bin/go tool cover -func="${coverageFile}")

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

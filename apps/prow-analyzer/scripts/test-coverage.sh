#!/bin/bash
# Shared local/CI unit entry point: enforce 100% coverage for ./pkg/...,
# then run bot command tests separately from that coverage gate.
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

#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

typeset suiteTag='unit'
typeset scriptDir=''
scriptDir=$(dirname -- "${BASH_SOURCE[0]}")
typeset goCommand="${GO-go}"
typeset packageText="${PKGS-./pkg/...}"
packageText="${packageText//$'\n'/ }"
typeset -a suitePackagesArr=()
read -r -a suitePackagesArr <<< "${packageText}"
case "${#}:${1-}" in
    '0:'|'1:--check-only') ;;
    *) printf 'Expected no arguments or --check-only\n' >&2; exit 2 ;;
esac

typeset coverageThreshold='100.0'
typeset coverageFile='coverage.out'
typeset coverageHTML='coverage.html'
typeset -a botPackagesArr=('./cmd/prow-analyzer--bot')

: 'Guarding that the unit build tag actually selects tests...'
GO="${goCommand}" "${scriptDir}/check--test-selection.sh" "${suiteTag}" "${suitePackagesArr[*]}" 1
if [[ "${1-}" == '--check-only' ]]; then
    exit 0
fi
: 'Running unit tests with coverage...'
"${goCommand}" test -v -tags "${suiteTag}" -covermode=set -coverprofile="${coverageFile}" "${suitePackagesArr[@]}"
: 'Generating coverage report...'
"${goCommand}" tool cover -html="${coverageFile}" -o "${coverageHTML}"
: 'Calculating coverage percentage...'
typeset coverageOutput=''
coverageOutput=$("${goCommand}" tool cover -func="${coverageFile}")
: "${coverageOutput}"
typeset totalCoverage=''
totalCoverage=$(printf '%s\n' "${coverageOutput}" | grep 'total:' | awk '{print $3}' | sed 's/%//')
: "Total coverage: ${totalCoverage}%"
: "Required coverage: ${coverageThreshold}%"
typeset -i isBelowThreshold=0
isBelowThreshold=$(printf '%s\n' "${totalCoverage} < ${coverageThreshold}" | bc -l)
if (( isBelowThreshold )); then
    : "❌ FAIL: Coverage ${totalCoverage}% is below threshold ${coverageThreshold}%"
    : "Coverage report: ${coverageHTML}"
    exit 1
fi
: "✅ PASS: Coverage ${totalCoverage}% meets threshold ${coverageThreshold}%"
: "Coverage report: ${coverageHTML}"
: 'Guarding that the unit build tag selects bot tests...'
GO="${goCommand}" "${scriptDir}/check--test-selection.sh" "${suiteTag}" "${botPackagesArr[*]}" 1
: 'Running bot env-consumer unit tests (outside the coverage gate)...'
"${goCommand}" test -v -tags "${suiteTag}" "${botPackagesArr[@]}"
true

#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

typeset suiteTag='unit'
typeset -r suiteTag
typeset scriptDir=''
scriptDir=$(dirname -- "${BASH_SOURCE[0]}")
typeset -r scriptDir
source "${scriptDir}/check--test-selection.sh"

typeset coverageThreshold='100.0'
typeset -r coverageThreshold
typeset coverageFile='coverage.out'
typeset -r coverageFile
typeset coverageHTML='coverage.html'
typeset -r coverageHTML
typeset -a botPackagesArr=('./cmd/prow-analyzer--bot')
typeset -r botPackagesArr

: 'Guarding that the unit build tag actually selects tests...'
CheckTestSelection "${suiteTag}" 1 "${suitePackagesArr[@]}"
if [[ "${isCheckOnly}" == true ]]; then
    exit 0
fi
: 'Running unit tests with coverage...'
"${goCommand}" test -v -tags "${suiteTag}" -covermode=set -coverprofile="${coverageFile}" "${suitePackagesArr[@]}"
: 'Generating coverage report...'
"${goCommand}" tool cover -html="${coverageFile}" -o "${coverageHTML}"
: 'Calculating coverage percentage...'
typeset coverageOutput=''
coverageOutput=$("${goCommand}" tool cover -func="${coverageFile}")
typeset -r coverageOutput
: "${coverageOutput}"
typeset totalCoverage=''
totalCoverage=$(printf '%s\n' "${coverageOutput}" | grep 'total:' | awk '{print $3}' | sed 's/%//')
typeset -r totalCoverage
: "Total coverage: ${totalCoverage}%"
: "Required coverage: ${coverageThreshold}%"
typeset -i isBelowThreshold=0
isBelowThreshold=$(printf '%s\n' "${totalCoverage} < ${coverageThreshold}" | bc -l)
typeset -r isBelowThreshold
if (( isBelowThreshold )); then
    : "❌ FAIL: Coverage ${totalCoverage}% is below threshold ${coverageThreshold}%"
    : "Coverage report: ${coverageHTML}"
    exit 1
fi
: "✅ PASS: Coverage ${totalCoverage}% meets threshold ${coverageThreshold}%"
: "Coverage report: ${coverageHTML}"
: 'Guarding that the unit build tag selects bot tests...'
CheckTestSelection "${suiteTag}" 1 "${botPackagesArr[@]}"
: 'Running bot env-consumer unit tests (outside the coverage gate)...'
"${goCommand}" test -v -tags "${suiteTag}" "${botPackagesArr[@]}"
true

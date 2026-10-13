#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset suiteTag='unit' scriptDir=''
typeset goCommand="${GO-go}" packageText="${PKGS-./pkg/...}"
scriptDir="$(
    dirname -- "${BASH_SOURCE[0]}"
)"
packageText="${packageText//$'\n'/ }"
typeset -a suitePackagesArr=(); read -r -a suitePackagesArr 0<<<"${packageText}"$'\n'
case "${#}:${1-}" in
    '0:'|'1:--check-only') ;;
    *) printf 'Expected no arguments or --check-only\n' >&2; exit 2 ;;
esac

typeset coverageThreshold='100.0' coverageFile='coverage.out' coverageHTML='coverage.html'
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
typeset coverageOutput='' totalCoverage=''
coverageOutput="$(
    "${goCommand}" tool cover -func="${coverageFile}"
)"
: "${coverageOutput}"
totalCoverage="$(
    printf '%s\n' "${coverageOutput}" |
    grep 'total:' | awk '{print $3}' | sed 's/%//'
)"
: "Total coverage: ${totalCoverage}%"
: "Required coverage: ${coverageThreshold}%"
typeset -i isBelowThreshold=0
isBelowThreshold="$(
    printf '%s\n' "${totalCoverage} < ${coverageThreshold}" | bc -l
)"
if ((isBelowThreshold)); then
    : "❌ FAIL: Coverage ${totalCoverage}% is below threshold ${coverageThreshold}%"
    : "Coverage report: ${coverageHTML}"
    false
else
    : "✅ PASS: Coverage ${totalCoverage}% meets threshold ${coverageThreshold}%"
    : "Coverage report: ${coverageHTML}"
fi
: 'Guarding that the unit build tag selects bot tests...'
GO="${goCommand}" "${scriptDir}/check--test-selection.sh" "${suiteTag}" "${botPackagesArr[*]}" 1
: 'Running bot env-consumer unit tests (outside the coverage gate)...'
"${goCommand}" test -v -tags "${suiteTag}" "${botPackagesArr[@]}"
true

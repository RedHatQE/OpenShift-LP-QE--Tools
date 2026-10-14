#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit extglob

typeset chkOnly="${1:-}"; (($#)) && shift

case "${#}:${chkOnly}" in
  (0:?(--check-only))   ;;
  (*)
    echo 'Expected no arguments or `--check-only`.'
    exit 2
    ;;
esac

typeset scrDir="${BASH_SOURCE[0]%/*}"
typeset suiteTag='unit'
typeset goCmd="${GO-go}"
typeset -a suitePkgArr="(${PKGS-./pkg/...})"

typeset coverageThreshold='100.0' coverageFile='coverage.out' coverageHTML='coverage.html'
typeset -a botPkgArr=('./cmd/prow-analyzer--bot')

: 'Guarding that the unit build tag actually selects tests...'
GO="${goCmd}" \
    "${scrDir}/check--test-selection.sh" \
    "${suiteTag}" \
    "${suitePkgArr[*]@Q}" \
    1

[ -z "${chkOnly}" ] || exit 0
: 'Running unit tests with coverage...'
"${goCmd}" test -v -tags "${suiteTag}" -covermode=set -coverprofile="${coverageFile}" "${suitePkgArr[@]}"
: 'Generating coverage report...'
"${goCmd}" tool cover -html="${coverageFile}" -o "${coverageHTML}"
: 'Calculating coverage percentage...'
typeset coverageOutput='' totalCoverage=''
coverageOutput="$(
    "${goCmd}" tool cover -func="${coverageFile}"
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
GO="${goCmd}" \
    "${scrDir}/check--test-selection.sh" \
    "${suiteTag}" \
    "${botPkgArr[*]@Q}" \
    1
: 'Running bot env-consumer unit tests (outside the coverage gate)...'
"${goCmd}" test -v -tags "${suiteTag}" "${botPkgArr[@]}"
true

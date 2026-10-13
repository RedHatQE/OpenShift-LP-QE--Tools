#!/bin/bash
# Fail when a build tag selects fewer tests than required; a zero-test run
# can otherwise succeed without exercising the intended suite.
set -euxo pipefail; shopt -s inherit_errexit

typeset buildTag="${1:?usage: check--test-selection.sh <buildTag> [packages] [minCount]}"; (($#)) && shift
typeset pkgsTest="${1:-./pkg/...}"; (($#)) && shift
typeset -i minCount="${1:-1}"; (($#)) && shift

typeset goCommand="${GO-go}" testList=''
typeset -i selected=0
typeset -a packageArr=(); read -r -a packageArr 0<<<"${pkgsTest}"$'\n'

: "Checking that \`-tags ${buildTag}\` selects at least ${minCount} test(s) in ${pkgsTest}..."
# The `go test -list` compiles the (tagged) test binaries and prints
#   one function name per line, plus a per-package summary line. Count
#   only the function names.
testList="$(
    "${goCommand}" test -tags "${buildTag}" -list '.*' "${packageArr[@]}"
)"
selected="$(
    printf '%s\n' "${testList}" |
    awk '/^(Test|Benchmark|Fuzz|Example)/ {count++} END {print count+0}'
)"

if ((selected < minCount)); then
    : "❌ FAIL: The \`-tags ${buildTag}\` selected ${selected} test(s) in ${pkgsTest} (expected >= ${minCount})."
    : "    A missing or misspelled `//go:build ${buildTag}` line yields 0 test silently."
    false
else
    : "✅ PASS: The \`-tags ${buildTag}\` selected ${selected} test(s) in ${pkgsTest}."
fi


true

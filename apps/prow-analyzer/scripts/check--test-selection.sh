#!/bin/bash
# Fail when a build tag selects fewer tests than required; a zero-test run
# can otherwise succeed without exercising the intended suite.
# Usage: check--test-selection.sh <build-tag> [packages] [minCount]
set -euxo pipefail; shopt -s inherit_errexit

typeset buildTag="${1:?usage: check--test-selection.sh <buildTag> [packages] [minCount]}"; (($#)) && shift
typeset packageText="${1:-./pkg/...}"; (($#)) && shift
packageText="${packageText//$'\n'/ }"
typeset -i minCount="${1:-1}"; (($#)) && shift
typeset goCommand="${GO-go}"
typeset -a packageArr=()
read -r -a packageArr <<< "${packageText}"

: "Checking that -tags ${buildTag} selects at least ${minCount} test(s) in ${packageText}..."

# `go test -list` compiles the (tagged) test binaries and prints one function
# name per line, plus a per-package summary line. Count only the function names.
typeset testList=''
testList=$("${goCommand}" test -tags "${buildTag}" -list '.*' "${packageArr[@]}")
typeset -i selected=0
selected=$(printf '%s\n' "${testList}" | awk '/^(Test|Benchmark|Fuzz|Example)/ {count++} END {print count+0}')

if (( selected < minCount )); then
    : "❌ FAIL: -tags ${buildTag} selected ${selected} test(s) in ${packageText} (expected >= ${minCount})."
    : "        A missing or misspelled //go:build ${buildTag} line yields 0 tests silently."
    exit 1
fi

: "✅ PASS: -tags ${buildTag} selected ${selected} test(s) in ${packageText}."

true

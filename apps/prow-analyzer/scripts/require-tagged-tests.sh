#!/bin/bash
# require-tagged-tests.sh — fail if a Go build tag selects no tests.
#
# Build tags are silent: a missing or misspelled `//go:build <tag>` line makes
# `go test -tags <tag> ./...` compile with zero matching tests and exit 0 (green),
# hiding the fact that the suite never ran. This guard turns that into a hard
# failure so the CI/Make contract can trust that a tagged suite actually exists.
#
# Usage: require-tagged-tests.sh <build-tag> [packages] [minCount]
set -euxo pipefail
# inherit_errexit needs bash >= 4.4 (CI); degrade gracefully on older bash (macOS 3.2)
shopt -s inherit_errexit 2>/dev/null || true

typeset -r buildTag="${1:?usage: require-tagged-tests.sh <build-tag> [packages] [minCount]}"
typeset -r pkgs="${2:-./pkg/...}"
typeset -ri minCount="${3:-1}"

: "Checking that -tags ${buildTag} selects at least ${minCount} test(s) in ${pkgs}..."

# `go test -list` compiles the (tagged) test binaries and prints one function
# name per line, plus a per-package summary line. Count only the function names.
typeset -i selected
# shellcheck disable=SC2086 # word-splitting of ${pkgs} into multiple patterns is intentional
selected=$(go test -tags "${buildTag}" -list '.*' ${pkgs} | grep -cE '^(Test|Benchmark|Fuzz|Example)' || true)

if (( selected < minCount )); then
    : "❌ FAIL: -tags ${buildTag} selected ${selected} test(s) in ${pkgs} (expected >= ${minCount})."
    : "        A missing or misspelled //go:build ${buildTag} line yields 0 tests silently."
    exit 1
fi

: "✅ PASS: -tags ${buildTag} selected ${selected} test(s) in ${pkgs}."

true

#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

typeset goCommand="${GO-go}"
typeset -r goCommand
typeset packageText="${PKGS-./pkg/...}"
packageText="${packageText//$'\n'/ }"
typeset -r packageText
typeset -a suitePackagesArr=()
read -r -a suitePackagesArr <<< "${packageText}"
typeset -r suitePackagesArr

typeset isCheckOnly=false
case "${#}" in
    0) ;;
    1)
        if [[ "${1}" != '--check-only' ]]; then
            printf 'Unsupported argument: %s\n' "${1}" >&2
            exit 2
        fi
        isCheckOnly=true
        ;;
    *)
        printf 'Expected no arguments or --check-only\n' >&2
        exit 2
        ;;
esac
typeset -r isCheckOnly

function CheckTestSelection() {
    typeset tag="${1}"
    typeset -r tag
    typeset -i minimum="${2}"
    typeset -r minimum
    shift 2
    typeset -a selectedPackagesArr=("${@}")
    typeset -r selectedPackagesArr
    : "Checking that -tags ${tag} selects at least ${minimum} test(s) in ${selectedPackagesArr[*]}..."
    typeset testList=''
    testList=$("${goCommand}" test -tags "${tag}" -list '.*' "${selectedPackagesArr[@]}")
    typeset -r testList
    typeset -i selected=0
    selected=$(printf '%s\n' "${testList}" | awk '/^(Test|Benchmark|Fuzz|Example)/ {count++} END {print count+0}')
    typeset -r selected
    if (( selected < minimum )); then
        : "❌ FAIL: -tags ${tag} selected ${selected} test(s) in ${selectedPackagesArr[*]} (expected >= ${minimum})."
        : "        A missing or misspelled //go:build ${tag} line yields 0 tests silently."
        exit 1
    fi
    : "✅ PASS: -tags ${tag} selected ${selected} test(s) in ${selectedPackagesArr[*]}."
    true
}

true

#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset suiteTag='integration' scriptDir=''
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

GO="${goCommand}" "${scriptDir}/check--test-selection.sh" "${suiteTag}" "${suitePackagesArr[*]}" 1
if [[ "${1-}" == '--check-only' ]]; then
    exit 0
fi
"${goCommand}" test -v -tags "${suiteTag}" -race "${suitePackagesArr[@]}"
true

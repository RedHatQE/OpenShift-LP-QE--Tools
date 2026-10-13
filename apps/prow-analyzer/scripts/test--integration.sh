#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

typeset suiteTag='integration'
typeset -r suiteTag
typeset scriptDir=''
scriptDir=$(dirname -- "${BASH_SOURCE[0]}")
typeset -r scriptDir
source "${scriptDir}/check--test-selection.sh"

CheckTestSelection "${suiteTag}" 1 "${suitePackagesArr[@]}"
if [[ "${isCheckOnly}" == true ]]; then
    exit 0
fi
"${goCommand}" test -v -tags "${suiteTag}" -race "${suitePackagesArr[@]}"
true

#!/bin/bash
# Local / manual runner for ExitTrap--PostProcessPrep.
#
# Exports used for verification (override any by exporting before invoking this
# script, or edit the defaults below):
#   export ARTIFACT_DIR="/home/oharan/OpenShift-LP-QE--Tools/libs/bash/ci-operator/interop/common"
#   export SHARED_DIR="/home/oharan/OpenShift-LP-QE--Tools/libs/bash/ci-operator/interop/common"
#   export REPORTPORTAL_CMP="lp-interop-Openshift-Pipelines"
#
# Optional positional args: same as ExitTrap--PostProcessPrep (e.g. merge output
# basename: junit--unique.xml). Defaults to jUnit.xml when omitted.
#
# Warning: the trap merges all *.xml under ARTIFACT_DIR (except the merge output),
# then tars and removes those source files. Use a disposable copy of fixtures if
# you do not want to delete real inputs.

set -euxo pipefail
shopt -s inherit_errexit

typeset SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export ARTIFACT_DIR="${ARTIFACT_DIR:-${SCRIPT_DIR}}"
export SHARED_DIR="${SHARED_DIR:-${ARTIFACT_DIR}}"
export REPORTPORTAL_CMP="${REPORTPORTAL_CMP:-lp-interop-Openshift-Pipelines}"

sh "${SCRIPT_DIR}/ExitTrap--PostProcessPrep.sh"



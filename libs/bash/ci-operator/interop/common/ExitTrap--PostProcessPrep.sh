#!/bin/bash

# When REPORTPORTAL_CMP is set, prefix each file's testsuite +@name with
# "${REPORTPORTAL_CMP}--" (in-place). No-op if unset or empty.
function PrefixTestsuiteNames () {
    [[ -n "${REPORTPORTAL_CMP:-}" ]] || return 0
    export cmp="${REPORTPORTAL_CMP}--"
    typeset f
    for f in "$@"; do
        yq eval -px -ox -iI0 '.testsuites.testsuite.+@name |= sub("^(.*)$", env(cmp) + "${1}")' $f || echo "Warning: yq failed for ${f}, debug manually" >&2
    done
    true
}

# Merge jUnit XML inputs into "${ARTIFACT_DIR}/${1}" and recompute per-suite counts.
function MergeJunits () {
    typeset mergedFN="${1:?}"; shift
    (($#)) || return 1
    yq eval-all -px -ox -I2 '
        [.] | {
            "+p_xml": "version=\"1.0\" encoding=\"UTF-8\"",
            "testsuites": {"testsuite": [
                .[][] |
                select(kind == "map") |
                (.testsuite // .) |
                ([] + .)[] |
                ([] + (.testcase // [])) as $tc |
                ."+@tests" = ($tc | length | tostring) |
                ."+@failures" = ([$tc[] | select(.failure)] | length | tostring) |
                ."+@errors" = ([$tc[] | select(.error)] | length | tostring)
            ]}
        }
    ' "$@" 1> "${ARTIFACT_DIR}/${mergedFN}"
    true
}

function Exit--TrapPostProcessPrep () {(
################################################################################
#   Exit Trap for CI Operator Step that executes the actual Test Cases.
#
#   CI Operator Step Script Trap Function to perform required actions necessary
#   for post-processing.
#
#   Workflow:
#    1. Collect jUnit XML test results from `${ARTIFACT_DIR}/`.
#    2. If `REPORTPORTAL_CMP` is non-empty, update each file in-place: every
#       testsuite +@name is prefixed with "${REPORTPORTAL_CMP}--".
#    3. Merge them into one jUnit XML (recount tests / failures / errors).
#    4. Archive the original jUnit XMLs into `${ARTIFACT_DIR}/jUnit-original.tgz`
#       and remove the loose copies.
#    5. Put the merged jUnit XML into `${SHARED_DIR}/` for consumption of the
#       subsequent Step.
#
#   Usage:
#       eval "$(
#           curl -fsSL \
#       https://<urlAuthToRawContent>/<urlPathToRawContents...>\
#       <repoPaths...>/ExitTrap--PostProcessPrep.sh
#       )"; trap '
#           ExitTrap--PostProcessPrep junit--<unique-merge-filename>.xml
#       ' EXIT
#
#   Optional Env. Var. from Step Configuration:
#       REPORTPORTAL_CMP
#           When set, PrefixTestsuiteNames prefixes each testsuite
#           +@name with "${REPORTPORTAL_CMP}--" before merge. Unset skips rename.
#
#   Used CI Operator default Env. Var.:
#       ARTIFACT_DIR
#       SHARED_DIR
################################################################################
    set -euxo pipefail; shopt -s inherit_errexit
    typeset mergedFN="${1:-jUnit.xml}"; (($#)) && shift

    typeset resultFile=''
    typeset -a xmlFiles=()

    # Ensure requirements are met.
    eval "$(
        curl -fsSL \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/\
libs/bash/common/EnsureReqs.sh
    )"; EnsureReqs yq

    while IFS= read -r -d '' resultFile; do
        grep -qE '<testsuites?\b' "${resultFile}" && xmlFiles+=("${resultFile}")
    done 0< <(
        find "${ARTIFACT_DIR}" \
            -type f -iname "*.xml" ! -name "${mergedFN}" \
            -print0
    )

    ((${#xmlFiles[@]})) || {
        : 'WARNING: No jUnit XML file found to process!'
        return
    }

    PrefixTestsuiteNames "${xmlFiles[@]}"
    # MergeJunits "${mergedFN}" "${xmlFiles[@]}"

    # Archive the original jUnit XMLs.
    {
        tar \
            zcf "${ARTIFACT_DIR}/jUnit-original.tgz" \
            -C "${ARTIFACT_DIR}/" \
            "${xmlFiles[@]#${ARTIFACT_DIR}/}" &&
        rm -f "${xmlFiles[@]}"
    }

    # The Data Router Step needs to be able to fetch the merged jUnit XML.
    cp "${ARTIFACT_DIR}/${mergedFN}" "${SHARED_DIR}/"

    true
)}

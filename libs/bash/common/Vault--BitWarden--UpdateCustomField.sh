#!/bin/bash
function Vault--BitWarden--UpdateCustomField () {
    typeset __shOpt="$(shopt -po errexit nounset xtrace pipefail; shopt -p inherit_errexit)"
    trap 'eval "${__shOpt}"; unset __shOpt; trap - RETURN' RETURN
    set -euxo pipefail; shopt -s inherit_errexit
################################################################################
#   Create or update a custom field of a BitWarden Object.
#
#   Usage:
#       eval "$(
#           typeset -a _fURL=()
#           type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
#           "${_fURL[@]}" \
#       https://<urlAuthToRawContent>/<urlPathToRawContents...>\
#       <repoPaths...>/Vault--BitWarden--UpdateCustomField.sh
#       )"; Vault--BitWarden--UpdateCustomField \
#           BW_OBJ_NAME BW_CRD_PATH BW_FLD_NAME BW_FLD_PATH
#
#   Args:
#       BW_OBJ_NAME Name of the BitWarden Object (Login, Note, etc.).
#       BW_CRD_PATH Path to a JSON file containing BitWarden Credentials.
#                   JSON Schema:
#                     {
#                       "client_id":"...",
#                       "client_secret":"...",
#                       "master_password":"..."
#                     }
#       BW_FLD_NAME Name of the custom field to create or update.
#       BW_FLD_PATH Path to a file containing the custom field value.
#                   Supports process substitution (e.g., <(...)).
################################################################################
    typeset bwObjName="${1:?}"; (($#)) && shift
    typeset bwCrdPath="${1:?}"; (($#)) && shift
    typeset bwFldName="${1:?}"; (($#)) && shift
    typeset bwFldPath="${1:?}"; (($#)) && shift

    typeset bwData='' bwItemID=''

    ( set +x
        trap 'bw logout 1> /dev/null 2>&1 || true' EXIT

        export BW_SESSION="$(
            eval "$(jq -r '"export BW_CLIENTID=\(
                .client_id | @sh
            ); export BW_CLIENTSECRET=\(
                .client_secret | @sh
            ); export BW_PASSWORD=\(
                .master_password | @sh
            )"' "${bwCrdPath}")"
            bw login --apikey 1> /dev/null
            bw unlock --passwordenv BW_PASSWORD --raw
        )"

        bw sync
        bwData="$(bw get item "${bwObjName}")" || {
            echo "You may NOT have access to BitWarden Object \`${bwObjName}\`." 1>&2
            exit 1
        }
        bwItemID="$(jq -cr '.id' 0<<<"${bwData}")"
        bwData="$(jq -r \
            --arg sfN "${bwFldName}" \
            --rawfile sfV "${bwFldPath}" \
            '.fields|=(
                map(select(.name != $sfN)) +
                [{name: $sfN, value: $sfV, type: 1}]
            )' \
        0<<<"${bwData}")"
        bw encode 0<<<"${bwData}" | bw edit item "${bwItemID}" 1> /dev/null
    true )

    true
}

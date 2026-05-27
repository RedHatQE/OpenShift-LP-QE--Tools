#!/bin/bash
function Vault--BitWarden--UploadAttachment () {
    typeset __shOpt="$(shopt -po errexit nounset xtrace pipefail; shopt -p inherit_errexit)"
    trap 'eval "${__shOpt}"; unset __shOpt; trap - RETURN' RETURN
    set -euxo pipefail; shopt -s inherit_errexit
################################################################################
#   Upload file as attachment to BitWarden.
#
#   Usage:
#       eval "$(
#           typeset -a _fURL=()
#           type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
#           "${_fURL[@]}" \
#       https://<urlAuthToRawContent>/<urlPathToRawContents...>\
#       <repoPaths...>/Vault--BitWarden--UploadAttachment.sh
#       )"; Vault--BitWarden--UploadAttachment \
#           BW_OBJ_NAME BW_CRD_PATH BW_FILE_ATT
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
#       BW_FILE_ATT Path to file to be uploaded.
################################################################################
    typeset bwObjName="${1:?}"; (($#)) && shift
    typeset bwCrdPath="${1:?}"; (($#)) && shift
    typeset bwAttFilePath="${1:?}"; (($#)) && shift

    typeset bwItemID='' e=''

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
        bwItemID="$(bw get item "${bwObjName}" | jq -r '.id')" || {
            echo "You may NOT have access to BitWarden Object \`${bwObjName}\`." 1>&2
            exit 1
        }
        while IFS='' read -r e; do
            bw delete --itemid "${bwItemID}" attachment "${e}" || {
                echo "You do NOT have R/W access to BitWarden Object \`${bwObjName}\`." 1>&2
                exit 1
            }
        done 0< <(
            bw get item "${bwObjName}" |
            jq -r --arg fn "${bwAttFilePath##*/}" '
                (.attachments // [])[] | select(.fileName == $fn) | .id
            '
        )
        bw create --file "${bwAttFilePath}" --itemid "${bwItemID}" attachment 1> /dev/null
    true )

    true
}

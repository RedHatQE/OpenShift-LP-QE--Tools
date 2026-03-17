#!/bin/bash
function EnsureReqs () {
    typeset __shOpt="$(shopt -po errexit nounset xtrace pipefail; shopt -p inherit_errexit)"
    trap 'eval "${__shOpt}"; unset __shOpt; trap - RETURN' RETURN
    set -euxo pipefail; shopt -s inherit_errexit
################################################################################
#   Check and install the required tools.
#
#   Usage:
#       eval "$(
#           curl -fsSL \
#       https://<urlAuthToRawContent>/<urlPathToRawContents...>\
#       <repoPaths...>/EnsureReqs.sh
#       )"; EnsureReqs <tools...>
#
#   Supported tools:
#     - jq
#     - yq
################################################################################
    typeset -a toolArr=("$@"); (($#)) && shift $#

    export PATH="$(exec 3>&1 1>&2
        typeset binDir="/tmp/bin" toolName=
        mkdir -p "${binDir}"
        while IFS= read -rd '' toolName; do
            case ${toolName} in
              (jq)
                jq --version || {
                    wget -qO "${binDir}/jq" \
                        "https://github.com/jqlang/jq/releases/latest/download/jq-$(
                            uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/'
                        )-$(
                            uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'
                        )" &&
                    chmod a+x "${binDir}/jq"
                    "${binDir}/jq" --version
                }
                ;;
              (yq)
                yq --version || {
                    wget -qO "${binDir}/yq" \
                        "https://github.com/mikefarah/yq/releases/latest/download/yq_$(
                            uname -s | tr '[:upper:]' '[:lower:]'
                        )_$(
                            uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'
                        )" &&
                    chmod a+x "${binDir}/yq"
                    "${binDir}/yq" --version
                }
                ;;
              (*)   : "Unsupported tool: ${toolName}";;
            esac
        done 0< <(printf '%s\0' "${toolArr[@]}")
        [[ ":${PATH}:" != *":${binDir}:"* ]] && echo "${binDir}:" 1>&3
    )${PATH}"

    true
}

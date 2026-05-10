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
#     - chisel
#     - bw
################################################################################
    typeset -a toolArr=("$@"); (($#)) && shift $#

    PATH="$(exec 3>&1 1>&2
        typeset binDir="/tmp/bin" toolName=
        mkdir -p "${binDir}"
        while IFS= read -rd '' toolName; do
            case ${toolName} in
              (jq)
                jq --version || {
                    curl -fsSL -o "${binDir}/jq" \
                        "https://github.com/jqlang/jq/releases/latest/download/jq-$(
                            uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/'
                        )-$(
                            uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'
                        )" &&
                    chmod a+x "${binDir}/${toolName}"
                    "${binDir}/${toolName}" --version
                }
                ;;
              (yq)
                yq --version || {
                    curl -fsSL -o "${binDir}/yq" \
                        "https://github.com/mikefarah/yq/releases/latest/download/yq_$(
                            uname -s | tr '[:upper:]' '[:lower:]'
                        )_$(
                            uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'
                        )" &&
                    chmod a+x "${binDir}/${toolName}"
                    "${binDir}/${toolName}" --version
                }
                ;;
              (chisel)
                # Chisel Secure Tunnel (https://github.com/jpillora/chisel).
                #   Provide a HTTP-over-WebSocket reverse tunnel, to expose
                #   local HTTP Server, in an ingress-less host, to a
                #   client-reachable EndPoint.
                chisel --version || {
                    curl -fsSL 'https://i.jpillora.com/chisel' \
                        | env -C "${binDir}" bash
                    "${binDir}/chisel" --version
                }
                ;;
              (bw)
                ${toolName} --version || (
                    typeset dlFile=/tmp/bw-cli--$$
                    wget -qO "${dlFile}.zip" 'https://bitwarden.com/download/?app=cli&platform=linux'
                    unzip "${dlFile}.zip" -d "${binDir}"
                    rm -rf "${dlFile}.zip"
                    "${binDir}/${toolName}" --version
                )
                ;;
              (*)   : "Unsupported tool: ${toolName}";;
            esac
        done 0< <(printf '%s\0' "${toolArr[@]}")
        [[ ":${PATH}:" != *":${binDir}:"* ]] && echo "${binDir}:" 1>&3
        true
    )${PATH}"

    true
}

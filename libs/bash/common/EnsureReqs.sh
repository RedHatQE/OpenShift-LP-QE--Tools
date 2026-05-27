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
#           typeset -a _fURL=()
#           type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
#           "${_fURL[@]}" \
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

    typeset -a _fURL=()

    type -t wget 1>/dev/null && _fURL=(wget -qO) || _fURL=(curl -fsSLo)
    PATH="$(exec 3>&1 1>&2
        typeset binDir="/tmp/bin" toolName=
        mkdir -p "${binDir}"
        while IFS= read -rd '' toolName; do
            case ${toolName} in
              (jq)
                ${toolName} --version || {
                    "${_fURL[@]}" "${binDir}/${toolName}" \
                        "https://github.com/jqlang/${toolName}/releases/latest/download/${toolName}-$(
                            uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/'
                        )-$(
                            uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'
                        )" &&
                    chmod a+x "${binDir}/${toolName}"
                    "${binDir}/${toolName}" --version
                }
                ;;
              (yq)
                ${toolName} --version || {
                    "${_fURL[@]}" "${binDir}/${toolName}" \
                        "https://github.com/mikefarah/${toolName}/releases/latest/download/${toolName}_$(
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
                ${toolName} --version || {
                    "${_fURL[@]}" - "$(
                        EnsureReqs jq
                        "${_fURL[@]}" - "https://api.github.com/repos/jpillora/${toolName}/releases/latest" |
                        jq -r \
                            --arg name "${toolName}" \
                            --arg os "$(uname -s | tr '[:upper:]' '[:lower:]')" \
                            --arg cpu "$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
                            '(.tag_name | ltrimstr("v")) as $tag | .assets[] | select(.name == "\($name)_\($tag)_\($os)_\($cpu).gz").browser_download_url'
                    )" | gunzip -c > "${binDir}/${toolName}"
                    chmod a+x "${binDir}/${toolName}"
                    "${binDir}/${toolName}" --version
                }
                ;;
              (bw)
                ${toolName} --version || (
                    typeset dlFile=/tmp/bw-cli--$$
                    "${_fURL[@]}" "${dlFile}.zip" "https://bitwarden.com/download/?app=cli&platform=$(
                        uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/'
                    )"
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

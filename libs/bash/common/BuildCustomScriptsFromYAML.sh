#!/bin/bash
function BuildCustomScriptsFromYAML () {
    typeset __shOpt="$(shopt -po errexit nounset xtrace pipefail; shopt -p inherit_errexit)"
    trap 'eval "${__shOpt}"; unset __shOpt; trap - RETURN' RETURN
    set -euxo pipefail; shopt -s inherit_errexit
################################################################################
#   Build User Defined Scripts.
#
#   The input is var. that its content (YAML) contains array or mapping of
#   custom shell scripts. This is converted to string of serially compounded
#   sub-shells, so each custom shell script is executed independently from
#   each other.
#
#   Each custom shell script will be executed with `set -euxo pipefail;
#   shopt -s inherit_errexit` context.
#
#   Usage:
#       eval "$(
#           curl -fsSL \
#       https://<urlAuthToRawContent>/<urlPathToRawContents...>\
#       <repoPaths...>/BuildCustomScriptsFromYAML.sh
#       )"; eval "$(BuildCustomScriptsFromYAML YAML_VAR_NAME)"
#
#   Args:
#       YAML_VAR_NAME   Name of var. containing YAML array or mapping of
#                       shell scripts.
#                       YAML Schema:
#                         - Array mode:
#                              |Scripts:
#                              |  - |-
#                              |    <shellScriptBlock>
#                         - Map mode (Key only serves as descriptive label):
#                              |Scripts:
#                              |  <description>: |-
#                              |    <shellScriptBlock>
################################################################################
    typeset yamlVar="${1}"; (($#)) && shift $#

    # Ensure requirements are met.
    eval "$(
        curl -fsSL \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/\
libs/bash/common/EnsureReqs.sh
    )"; EnsureReqs yq

    [[ -n "${!yamlVar}" ]] && yq eval '
        (.Scripts // error("Invalid YAML Schema!!!")) |
        .[] |
        "\n( set -euxo pipefail; shopt -s inherit_errexit\n" +
        . +
        "\ntrue )\n"
    ' 0<<<"${!yamlVar}"

    true
}

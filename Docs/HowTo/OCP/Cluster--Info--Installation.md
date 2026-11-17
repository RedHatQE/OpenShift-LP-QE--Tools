# Cluster -- Info -- Installation
## Bare Metal
### Installation
<details><summary>ABI (Agent-Based Installer)</summary>

**Pre-requisites:**
  - Pre-populate `${_OCP__ABI__CFG}` with the full `agent-config.yaml`, i.e. the Host definitions (NMState network config, BMC addresses) and any extra
    configuration needed:
    ```yaml
    Day0:
      config: {}
      configFileOverride:
        yaml+:
          - ...yamlCfg...:
              ...yamlCfgContentToDeepMergeAppendArray...
        yaml-:
          - ...yamlCfg...:
              ...yamlCfgContentToDeepMergeReplaceArray...
        yaml=:
          - ...yamlCfg...:
              ...yamlCfgContentToReplace...
        json+:
          - ...jsonCfg...: |
              ...jsonCfgContentToDeepMergeAppendArray...
        json-:
          - ...jsonCfg...: |
              ...jsonCfgContentToDeepMergeReplaceArray...
        json=:
          - ...jsonCfg...: |
              ...jsonCfgContentToReplace...
    Day1:   # Same schema as `Day0`
      ...
    Day1.5:
      config:
        - NodeProv: ...booleanNodeProvisioningStatus...
    Day2:   # Same schema as `Day1.5`
      ...
    ```

    **Notes:**
      - For each entry of `.Day<N>.configFileOverride.yaml` and `.Day<N>.configFileOverride.json`, its Key is a configuration file path relative to Cluster
        Installation Directory and its Value is the content to be deep-merged into the corresponding file.
      - The `.Day0` is meant to provide easy configuration options for Day 0 configuration files, such as `install-config.yaml`, `agent-config.yaml`, etc.
          - Minimal content required for `install-config.yaml`:
            ```yaml
            platform:
              baremetal:
                apiVIPs:
                  - '...apiVIP...'
                ingressVIPs:
                  - '...ingressVIP...'
            ```
          - Optional content for `agent-config.yaml`:
            ```yaml
            hosts:
              - bmc:
                  username: ...bmc1CrdUsr...
                  password: ...bmc1CrdPwd...
              - bmc:
                  username: ...bmc2CrdUsr...
                  password: ...bmc2CrdPwd...
               ...
            ```
      - The `.Day1` is meant to provide easy configuration options for Day 1 configuration files, such as manifest files.
      - The `."Day1.5".config` is an ordered list of post-bootstrap custom actions, executed in sequence:
          - Node Provisioning status.
            ```yaml
            NodeProv: false
            ```
            Scale Worker MachineSets to 0 replicas. Set when workers are provisioned directly by ABI without BareMetalHost CRDs or Ironic provisioning network
            (i.e. `.platform.baremetal.provisioningNetwork: Disabled` in `install-config.yaml`).
```shell
# OCP Installation ABI (Agent-Based Installation) on Bare Metal.
#   Installation Phases:
#     Day-0   Cluster Configuration.
#               First `CreateABIcfg` creates a bare-minimum
#               `install-config.yaml` and generates an `agent-config.yaml`
#               template. Then `UpdateCfg Day0` applies overrides from user
#               (`_OCP__ABI__CFG`). Use the custom script and/or interactive
#               session to further modify them, if desired. Both configuration
#               files must be complete before proceeding to Day-1.
#     Day-1   Manifest Customization.
#               Runs `agent create cluster-manifests`, if customization is
#               requested, to generate the full manifest tree under
#               `openshift/`. Then `UpdateCfg Day1` applies overrides from user
#               (`_OCP__ABI__CFG`), if any. Use the custom script and/or
#               interactive session to modify those manifest files, if
#               desired, before the ISO is built.
#     Day-1.5 Post-Bootstrap Operations.
#               Runs after `agent wait-for bootstrap-complete`. Applies custom
#               actions as configured by user (`_OCP__ABI__CFG`), if any.
#     Day-2   Post-Deployment Customization.
#               Runs after `agent wait-for install-complete` and `KUBECONFIG`
#               is set. Use the custom script and/or interactive session to
#               configure the running cluster (e.g. install operators, apply
#               policies, configure identity providers), if desired.
#   The `_OCP__INSTLR_FLG__CUSTOM` is a bit flag to control phase behaviour.
#     0x00000001    Interactive Session at the end of Day-0 Phase.
#     0x00000002    Interactive Session at the end of Day-1 Phase.
#     0x00000004    Interactive Session at the end of Day-2 Phase.
#       NOTE:   Exiting any of these Sessions with Exit Status 255 will stop
#               the whole Installation procedure.
#     0x00000008    Executing `_OCP__INSTLR_DAY0` during Day-0 Phase.
#     0x00000010    Executing `_OCP__INSTLR_DAY1` during Day-1 Phase.
#     0x00000020    Executing `_OCP__INSTLR_DAY2` during Day-2 Phase.
#       NOTE:   The content of these Env. Var. is executed via
#               `eval "( set -euxo pipefail; shopt -s inherit_errexit;
#               ${_OCP__INSTLR_...}; true )"` (in a sub-shell).
__SHELL=0 \
    _OCP__INSTLR_ACTION=1 \
    _OCP__INSTLR_FLG__CUSTOM=$((0x00)) \
    _OCP__INSTLR_DIR='...ocpInstallerDir...' \
    _OCP__INSTLR_DAY0="${_OCP__INSTLR_DAY0:-: 'Custom Day-0 Script.'}" \
    _OCP__INSTLR_DAY1="${_OCP__INSTLR_DAY1:-: 'Custom Day-1 Script.'}" \
    _OCP__INSTLR_DAY2="${_OCP__INSTLR_DAY2:-: 'Custom Day-2 Script.'}" \
    _OCP__INSTLR_MIN_ISO=1 \
    _OCP__INSTLR_WAIT__NODE_READY__M='...maxWaitForNodeToBeReadyInMin...' \
    _OCP__INSTLR_WAIT__BOOTSTRAP__TRY='...numOfTryToWaitForBootStrap...' \
    _OCP__INSTLR_WAIT__CLUSTER__TRY='...numOfTryToWaitForCluster...' \
    _OCP__CLUSTER_DIR='...ocpClusterDir...' \
    _OCP__INSTLR_LOG_LEVEL=info \
    _OCP__ABI__BM__BASE_DOM='...baseDomain...' \
    _OCP__ABI__BM__CLS_NAME='...clusterName...' \
    _OCP__ABI__BM__PULL_CRD='...pullSecretFile...' \
    _OCP__ABI__BM__SSH_KEY__PRV='...sshKeyFilePrv...' \
    _OCP__ABI__BM__SSH_KEY__PUB='...sshKeyFilePub...' \
    _OCP__ABI__CFG='...abiCfgFile...' \
    _BMC__CRD_USR='...bmcCrdUsr...' \
    _SVC__TUN__CRD_USR='...chiselCrdUsr...' \
    _SVC__TUN__CP_URL='...chiselServerCPurl...' \
    _SVC__TUN__DP_BASE_URL='...chiselServerDPbaseURL...' \
    _SVC__TUN__DP_PORT="${_SVC__TUN__DP_PORT:-8443}" \
    _BW__NOTE_NAME__BMC='...bwNoteNameForBMCdefaultCredentials...' \
    _BW__NOTE_NAME__SVC__TUN='...bwNoteNameForTunnelServiceCredentials...' \
    _BW__NOTE_NAME__OCP__KCFG='...bwNoteNameForOCPkubeconfig...' \
    _RC__SRCS='(...srcDirsOfRCfiles...)' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        {
            typeset __shOpt="$(shopt -po xtrace)"; set +x
            [ -n "${BW_SESSION}" ] && bw sync || {
                echo 'You do NOT have an active and sync:ed BitWarden Session!!!' 1>&2
                exit 1
            }
            # BMC.
            eval "$(
                typeset bwData=
                bwData="$(bw get item "${_BW__NOTE_NAME__BMC}")" || {
                    echo "You may NOT have access to BitWarden Note \`${_BW__NOTE_NAME__BMC}\`." 1>&2
                    echo false; exit 1
                }
                jq -r \
                    --arg fn__c "cred.BMC.${_BMC__CRD_USR}" \
                    '
                        .fields[]? | select(.name == $fn__c).value | fromjson |
                        (
                            "typeset -x " +
                            "bmcCrdUsr=\(.usr | @sh) " +
                            "bmcCrdPwd=\(.pwd | @sh)"
                        )
                    ' \
                0<<<"${bwData}"
            )"
            # Chisel Tunnel Service.
            chisel --version
            eval "$(
                typeset bwData=
                bwData="$(bw get item "${_BW__NOTE_NAME__SVC__TUN}")" || {
                    echo "You may NOT have access to BitWarden Note \`${_BW__NOTE_NAME__SVC__TUN}\`." 1>&2
                    echo false; exit 1
                }
                jq -r \
                    --arg fn__c "cred.${_SVC__TUN__CRD_USR}" \
                    '
                        .fields[]? | select(.name == $fn__c).value | fromjson |
                        (
                            "typeset -x " +
                            "chiselCrdUsr=\(.usr | @sh) " +
                            "chiselCrdPwd=\(.pwd | @sh)"
                        )
                    ' \
                0<<<"${bwData}"
            )"
            eval "${__shOpt}"; unset __shOpt
        }
        eval "$(
            typeset e1=
            mkdir -p -- "${_OCP__CLUSTER_DIR}"
            for e1 in _OCP__{CLUSTER,INSTLR}_DIR; do
                eval "${e1}=\"\$(CDPATH= cd -L \"\${${e1}}\" && pwd)\""
            done
            for e1 in _RC__SRCS; do
                eval "eval \"a1=\${${e1}}\""
                for e2 in "${a1[@]}"; do
                    eval "a2+=(\"\$(CDPATH= cd -L ${e2@Q} && pwd)\")"
                done
                eval "${e1}=\"(${a2[@]@Q})\""
            done
            typeset -p _OCP__{CLUSTER,INSTLR}_DIR _RC__SRCS
        )"
        typeset -i _OCP__INSTLR_FLG__CUSTOM="${_OCP__INSTLR_FLG__CUSTOM}"
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset kubeCfg="${_OCP__CLUSTER_DIR}/kubecfg"
        typeset bmcInfo="${_OCP__CLUSTER_DIR}/ocp--bmc--info.json"
        typeset +x bmcCrdUsr bmcCrdPwd
        typeset +x chiselCrdUsr chiselCrdPwd

        [ -r "${_OCP__ABI__CFG}" ]

        function openshift-install () {
            typeset -i es=0
            {
                echo \
"$(date -Iseconds)|${FUNCNAME[0]@Q} ${*@Q}"$'\n'"$(printf '%.0s-' {1..80})"
                "${_OCP__INSTLR_DIR}/openshift-install" \
                    --dir "${_OCP__CLUSTER_DIR}/" \
                    ${_OCP__INSTLR_LOG_LEVEL:+--log-level "${_OCP__INSTLR_LOG_LEVEL}"} \
                    "$@" 2>&1 || es=$?
                echo "$(printf '%.0s=' {1..80})"
                exit ${es}
            } | tee -a "${_OCP__CLUSTER_DIR}/ocp--installer--cluster.log"
            return ${PIPESTATUS[0]}
        }
        function EnterShell () {
            typeset -i asChild="${1:-1}"; (($#)) && shift
            export -f openshift-install
            cd "${_OCP__CLUSTER_DIR}/"
            if ((asChild)); then
                echo \
                    'Exit this interactive session, when you are finished, to' \
                    'continue (Exit Status 255 will cancel the installation).'
                "${SHELL}" || (($? != 255))
                cd - 1> /dev/null
            else
                echo 'Do NOT forget to exit this interactive session!!!'
                exec "${SHELL}"
            fi
            true
        }
        function CreateABIcfg () {
            # Create bare-minimum `install-config.yaml`.
            {
                yq -p yaml -o json eval . |
                jq -c \
                    --arg clsName "${_OCP__ABI__BM__CLS_NAME}" \
                    --arg baseDom "${_OCP__ABI__BM__BASE_DOM}" \
                    --rawfile pullCrd <(
                        jq -csj \
                            '.[0].auths += .[1].auths | .[0]' \
                            "/var/run/secrets/registry-pull--build-farms/.dockerconfigjson" \
                            "${_OCP__ABI__BM__PULL_CRD}"
                    ) \
                    --rawfile sshKey <(set +x; cat "${_OCP__ABI__BM__SSH_KEY__PUB}") \
                    '
                        .baseDomain=$baseDom |
                        .metadata.name=$clsName |
                        .pullSecret=$pullCrd |
                        .sshKey=$sshKey
                    ' |
                yq -p json -o yaml eval .
            } 0<<'fileEOF' 1> "${_OCP__CLUSTER_DIR}/install-config.yaml"
apiVersion: v1
baseDomain: ''
metadata:
  name: ''
platform: {none: {}}
pullSecret: ''
sshKey: ''
fileEOF
            # Enrich with OCP-version-aware defaults.
            openshift-install create install-config
            # Update for Bare Metal target.
            yq -i eval \
                '.platform={"baremetal": {}}' \
                "${_OCP__CLUSTER_DIR}/install-config.yaml"

            # Create `agent-config.yaml` template.
            openshift-install agent create agent-config-template
            # Being idempotent on re-run.
            [ -s "${_OCP__CLUSTER_DIR}/agent-config.yaml" ] || {
                jq -r \
                    '."*agentconfig.AgentConfig".File.Data' \
                    "${_OCP__CLUSTER_DIR}/.openshift_install_state.json" |
                base64 -d 1> "${_OCP__CLUSTER_DIR}/agent-config.yaml"
            }

            true
        }
        function UpdateCfg () {
            typeset topKey="${1:?}"; (($#)) && shift
            typeset cfgType= cfgFile= cfgCont= updateOp=
            while IFS=$'\t' read -r cfgType cfgFile cfgCont; do
                [[ "${cfgFile}" == */* ]] &&
                    mkdir -p "${_OCP__CLUSTER_DIR}/${cfgFile%/*}"
                1>> "${_OCP__CLUSTER_DIR}/${cfgFile}"
                exec 3< <(0< "${_OCP__CLUSTER_DIR}/${cfgFile}"); wait $!
                case ${cfgType} in
                  (*+)  updateOp='select(fileIndex==0) *+ ' ;;
                  (*-)  updateOp='select(fileIndex==0) * '  ;;
                  (*=)  updateOp=''                         ;;
                esac
                updateOp+='select(fileIndex==1)'
                case ${cfgType} in
                  (yaml+|yaml-|yaml=)
                    yq eval-all "${updateOp}" \
                        - \
                        <(set +x; yq -p json -o yaml eval . 0<<<"${cfgCont}") \
                        0<&3 1>"${_OCP__CLUSTER_DIR}/${cfgFile}"
                    ;;
                  (json+|json-|json=)
                    yq -p json -o json eval-all "${updateOp}" \
                        - \
                        <(set +x; echo "${cfgCont}") \
                        0<&3 1>"${_OCP__CLUSTER_DIR}/${cfgFile}"
                    ;;
                  (*)   : "Invalid Type: ${cfgType}"; false;;
                esac
                exec 3<&-
            done 0< <(
                yq -o json eval . "${_OCP__ABI__CFG}" |
                jq -r --arg k "${topKey}" '
                    (.[$k].configFileOverride // empty) | to_entries[] |
                    .key as $type | .value[]? | to_entries[] |
                    [$type, .key, (
                        if ($type | startswith("json")) then .value
                        else (.value | tojson)
                        end
                    )] | join("\t")
                '
            )
            true
        }
        function ExtractBMCinfo () {
            typeset bmcInfo="${1:?}"; (($#)) && shift

            # Retrieve BMC Information from `agent-config.yaml`.
            #   Currently, if all Master Nodes are ready to be installed, but
            #   not all Worker Nodes are registering, the
            #   `wait-for bootstrap-complete` will exit out with error.
            #   As workaround, we boot the Worker Nodes first, and the
            #   Rendezvous Host last.
            {
                yq -p yaml -o json eval . |
                jq \
                    --rawfile usr <(set +x; printf '%s' "${bmcCrdUsr}") \
                    --rawfile pwd <(set +x; printf '%s' "${bmcCrdPwd}") \
                    --argjson rIP "$(yq -o json '(select(
                        (.rendezvousIP | length) > 0) | .rendezvousIP
                    ) // ([
                        (.hosts[] | select(.role == "master")),
                        (.hosts[] | select(.role == "arbiter")),
                        (.hosts[] | select((.role == "") or (.role == null)))
                    ] | .[0] | [.networkConfig.interfaces[] |
                        select(.ipv4.enabled == true) |
                        .ipv4.address[0].ip
                    ] | .[0]) // error(
                        "rendezvousIP could not be determined"
                    ) ' "${_OCP__CLUSTER_DIR}/agent-config.yaml")" \
                    '[(
                        (.hosts[] | select(.role == "worker")),
                        ((
                            (.hosts[] | select((.role == "") or (.role == null))),
                            (.hosts[] | select(.role == "auto-assign")),
                            (.hosts[] | select(.role == "arbiter")),
                            (.hosts[] | select(.role == "master"))
                        ) | select(any((
                            .networkConfig.interfaces[] |
                            select(.ipv4.enabled == true) |
                            .ipv4.address[]?.ip
                        ); . == $rIP) | not)),
                        (.hosts[] | select(any((
                            .networkConfig.interfaces[] |
                            select(.ipv4.enabled == true) |
                            .ipv4.address[]?.ip
                        ); . == $rIP)))
                    ) | {
                        url: ("https://" + (.bmc.address | split("://")[-1])),
                        usr: (.bmc.username // $usr),
                        pwd: (.bmc.password // $pwd),
                        hostIPv4: ([
                            .networkConfig.interfaces[] |
                            select(.ipv4.enabled == true) |
                            .ipv4.address[0]?.ip
                        ][0] // null)
                    }]'
            } 0< "${_OCP__CLUSTER_DIR}/agent-config.yaml" 1> "${bmcInfo}"

            # Strip BMC Credentials from `agent-config.yaml`.
            exec 3< <(0< "${_OCP__CLUSTER_DIR}/agent-config.yaml"); wait $!
            {
                yq -p yaml -o json eval . |
                jq '.hosts[].bmc|=del(.username, .password)' |
                yq -p json -o yaml eval .
            } 0<&3 1> "${_OCP__CLUSTER_DIR}/agent-config.yaml"
            exec 3<&-

            true
        }

        case ${_OCP__INSTLR_ACTION} in
          (1)     (
            typeset -i iSes=0 fCstm=0 lsb=0
            {   # Preparation Phase.
                rm -f "${_OCP__CLUSTER_DIR}/auth/kubeconfig"
                unset KUBECONFIG
            }
            {   # Day-0 Phase.
                iSes=$((_OCP__INSTLR_FLG__CUSTOM & 0x01))
                fCstm=$(((_OCP__INSTLR_FLG__CUSTOM &= ~0x01) & ~0x03))
                CreateABIcfg
                UpdateCfg Day0
                while ((fCstm)); do
                    lsb=$((fCstm & -fCstm))
                    case ${lsb} in
                      (8)   printf "Day-0 Phase (0x%08x):\n" ${lsb};;&
                      (8)           (   # 0x000008  Executing Custom Day-0 Script.
eval '( set -euxo pipefail; shopt -s inherit_errexit
'"${_OCP__INSTLR_DAY0}"$'\ntrue )'
                      );;
                    esac
                    ((fCstm ^= lsb)) || true
                done
                ((iSes)) && echo 'Manual Day-0 Operation.' &&
                    PROMPT_COMMAND='PS1="${PS1%\[Day-0\] }[Day-0] "' EnterShell
                ExtractBMCinfo "${bmcInfo}"
                ((_OCP__INSTLR_MIN_ISO)) && (
                    export __IMG__ROOT_FS="${_SVC__TUN__DP_BASE_URL%%/}/${_SVC__TUN__DP_PORT}/boot-artifacts"
                    yq -i eval '
                        .minimalISO=true |
                        .bootArtifactsBaseURL=strenv(__IMG__ROOT_FS)
                    ' "${_OCP__CLUSTER_DIR}/agent-config.yaml"
                )
            }
            {   # Day-1 Phase.
                iSes=$((_OCP__INSTLR_FLG__CUSTOM & 0x02))
                fCstm=$(((_OCP__INSTLR_FLG__CUSTOM &= ~0x02) & ~0x03))
                { ((fCstm | iSes)) || {
                    yq -e eval '
                        .Day1.configFileOverride |
                        to_entries | .[].value[]
                    ' "${_OCP__ABI__CFG}" 1> /dev/null 2>&1
                }; } && openshift-install agent create cluster-manifests
                UpdateCfg Day1
                while ((fCstm)); do
                    lsb=$((fCstm & -fCstm))
                    case ${lsb} in
                      (16) printf "Day-1 Phase (0x%08x):\n" ${lsb};;&
                      (16)          (   # 0x000010  Executing Custom Day-1 Script.
eval '( set -euxo pipefail; shopt -s inherit_errexit
'"${_OCP__INSTLR_DAY1}"$'\ntrue )'
                      );;
                    esac
                    ((fCstm ^= lsb)) || true
                done
                ((iSes)) && echo 'Manual Day-1 Operation.' &&
                    PROMPT_COMMAND='PS1="${PS1%\[Day-1\] }[Day-1] "' EnterShell
            }
            {   # ISO Creation Phase.
                openshift-install agent create image
            }
            {   # Deployment Phase.
                (
                    typeset isoFile="$(
                        shopt -s nullglob
                        echo "${_OCP__CLUSTER_DIR}/agent."*.iso
                    )"
                    typeset isoURL="${_SVC__TUN__DP_BASE_URL%%/}/${_SVC__TUN__DP_PORT}/${isoFile##*/}"
                    typeset -i httpSvcPort=8080
                    typeset -ai taskPIDs=()

                    function HandleSIGCHLD () {
                        typeset -i i=0
                        for i in "${!taskPIDs[@]}"; do
                            kill -0 "${taskPIDs[i]}" 2>/dev/null ||
                            unset "taskPIDs[i]"
                        done
                        true
                    }
                    function RedfishAPIcall () {
                        typeset bmcInfo="${1:?}"; (($#)) && shift
                        typeset bmcURL="${1:?}"; (($#)) && shift
                        typeset apiMethod="${1:?}"; (($#)) && shift
                        typeset apiEP="${1?}"; (($#)) && shift
                        typeset -i es=0 tryLeft=6 httpCode=0
                        typeset httpResp=
                        while ((tryLeft)); do
                            es=0
                            httpResp=$(curl -sSLk -X "${apiMethod}" \
                                --fail-with-body \
                                -w '\n%{response_code}' \
                                -K <(
                                    set +x
                                    jq -r \
                                        --arg url "${bmcURL}" \
                                        '
                                            .[] |
                                            select(.url == $url) |
                                            "-u \("\(.usr):\(.pwd)" | @json)"
                                        ' \
                                    0< "${bmcInfo}"
                                ) \
                                -H 'Content-Type: application/json' \
                                -H 'Accept: application/json' \
                                "$@" \
                                "${bmcURL}/redfish/v1/${apiEP#/}") || es=$?
                            httpCode="${httpResp##*$'\n'}"
                            # Retry on 500,503: Transient server failure.
                            case ${httpCode} in
                              (500|503) ;;
                              (*)       break;;
                            esac
                            sleep 10
                            ((--tryLeft))
                        done
                        printf '%s' "${httpResp%$'\n'${httpCode}}"
                        return ${es}
                    }
                    function VCD-Eject () {
                        typeset bmcInfo="${1:?}"; (($#)) && shift
                        typeset bmcURL="${1:?}"; (($#)) && shift
                        typeset bmcMgrId="${1:?}"; (($#)) && shift
                        {
                            RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET \
                                "Managers/${bmcMgrId}/VirtualMedia/CD" |
                            jq -e '.Inserted == true' 1> /dev/null
                        } && {
                            RedfishAPIcall "${bmcInfo}" "${bmcURL}" POST \
                                "Managers/${bmcMgrId}/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia" \
                                -d '{}' ||
                            true
                        }
                        true
                    }
                    function Host-PowerControl () {
                        typeset bmcInfo="${1:?}"; (($#)) && shift
                        typeset bmcURL="${1:?}"; (($#)) && shift
                        typeset bmcSysId="${1:?}"; (($#)) && shift
                        typeset resetType="${1:?}"; (($#)) && shift
                        typeset -i es=0
                        RedfishAPIcall "${bmcInfo}" "${bmcURL}" POST \
                            "Systems/${bmcSysId}/Actions/ComputerSystem.Reset" \
                            -d "{\"ResetType\": \"${resetType}\"}" || es=$?
                        return ${es}
                    }
                    function WipeDisks () {
                        typeset -i tPID="${1:?}"; (($#)) && shift
                        typeset bmcInfo="${1:?}"; (($#)) && shift
                        typeset bmcURL="${1:?}"; (($#)) && shift
                        typeset bmcSysId="${1:?}"; (($#)) && shift
                        typeset bmcMgrId="${1:?}"; (($#)) && shift
                        typeset wipeMethod="${1?}"; (($#)) && shift
                        typeset rmtScript=
                        typeset -i es=0
                        case ${wipeMethod} in
                          ('')  rmtScript="$(cat - 0<<'sshEOF'
sudo bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'shEOF'
    grep -qE '\bcoreos\.live(\.|iso=)' /proc/cmdline || exit 193
    true
shEOF
)"
sshEOF
                          )";;&
                          (OS)  rmtScript="$(cat - 0<<'sshEOF'
sudo bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'shEOF'
    typeset dev=
    grep -qE '\bcoreos\.live(\.|iso=)' /proc/cmdline || exit 193
    udevadm settle
    while IFS= read -r dev; do
        sgdisk --zap-all "${dev}"
        wipefs -a "${dev}"
        blkdiscard "${dev}" 2> /dev/null || true
    done 0< <(
        lsblk -dpno NAME,TYPE | awk '($2 == "disk"){print $1}'
    )
    true
shEOF
)"
sshEOF
                            )";;&
                          ('')  ;&
                          (OS)  (
                            typeset stdErr= rgx=
                            typeset hostIPv4=
                            hostIPv4="$(jq -r \
                                --arg url "${bmcURL}" \
                                '.[] | select(.url == $url).hostIPv4' \
                            0< "${bmcInfo}")"
                            typeset -i tryLeft=$((2 * _OCP__INSTLR_WAIT__NODE_READY__M)) es=0
                            while ((tryLeft)); do
                                kill -0 "${tPID}" 2>/dev/null || break
                                sleep 30
                                es=0
                                stdErr="$({
                                    ssh -n \
                                        -o UserKnownHostsFile=/dev/null \
                                        -o StrictHostKeyChecking=no \
                                        -o ConnectTimeout=5 \
                                        -i "${_OCP__ABI__BM__SSH_KEY__PRV}" \
                                        "core@${hostIPv4}" \
                                        "${rmtScript}" \
                                        2> >(tee /dev/fd/3) 1>&3 ||
                                    es=$?
                                } 3>&2; exit ${es})" || es=$?
                                case ${es} in
                                  (0)   break;;
                                  (193) exit ${es};;
                                  (255)
                                    rgx='\bPermission denied \(.*\bpublickey\b.*\)'
                                    [[ "${stdErr}" =~ ${rgx} ]] && exit 255
                                    ;;
                                esac
                                ((--tryLeft))
                            done
                          ) || es=$?;;
                          (BMC) (
                            typeset ctrlId= volEP= driveEP= jobId=
                            typeset -a jobIds=()
                            while IFS= read -r ctrlId; do
                                while IFS= read -r volEP; do
                                    # Try `Volume.Initialize`.
                                    jobId="$(
                                        RedfishAPIcall "${bmcInfo}" "${bmcURL}" POST \
                                            "${volEP#/redfish/v1/}/Actions/Volume.Initialize" \
                                            -d '{
                                                "InitializeType": "Slow",
                                                "@Redfish.OperationApplyTime": "OnReset"
                                            }' -o /dev/null -D - |
                                        sed -nE 's/^[Ll]ocation: ([^\r]*)\r?$/\1/p;T;q'
                                    )" || true
                                    jobId="${jobId##*/}"
                                    [ -n "${jobId}" ] && jobIds+=("${jobId}") && continue
                                    # Fallback to `SecureErase` the Volume's Physical Drives.
                                    while IFS= read -r driveEP; do
                                        jobId="$(
                                            RedfishAPIcall "${bmcInfo}" "${bmcURL}" POST \
                                                "${driveEP#/redfish/v1/}/Actions/Drive.SecureErase" \
                                                -d '{}' -o /dev/null -D - |
                                            sed -nE 's/^[Ll]ocation: ([^\r]*)\r?$/\1/p;T;q'
                                        )" || true
                                        jobId="${jobId##*/}"
                                        [ -n "${jobId}" ] && jobIds+=("${jobId}")
                                    done 0< <(
                                        RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET \
                                            "${volEP#/redfish/v1/}" |
                                        jq -r '.Links.Drives[]?."@odata.id" // empty'
                                    )
                                done 0< <(
                                    RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET \
                                        "Systems/${bmcSysId}/Storage/${ctrlId}/Volumes" |
                                    jq -r '.Members[]?."@odata.id" // empty'
                                )
                            done 0< <(
                                RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET \
                                    "Systems/${bmcSysId}/Storage" |
                                jq -r '.Members[]."@odata.id" | split("/")[-1]'
                            )
                            # Restart Host.
                            Host-PowerControl "${bmcInfo}" "${bmcURL}" "${bmcSysId}" ForceRestart
                            # Wait for all wipe Jobs to complete.
                            while true; do
                                kill -0 "${tPID}" 2>/dev/null || break
                                sleep 60
                                for jobId in "${jobIds[@]}"; do
                                    {
                                        RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET \
                                            "Managers/${bmcMgrId}/Jobs/${jobId}" |
                                        jq -e '
                                            .JobState | test("^Completed"; "i")
                                        ' 1> /dev/null
                                    } && {
                                        RedfishAPIcall "${bmcInfo}" "${bmcURL}" DELETE \
                                            "Managers/${bmcMgrId}/Jobs/${jobId}" ||
                                        true
                                    } || continue 2
                                done
                                break
                            done
                          ) || es=$?;;
                          (*)   : "Unknown method: ${wipeMethod}"; es=1;;
                        esac
                        return ${es}
                    }

                    ((__SHELL)) || trap 'HandleSIGCHLD' CHLD
                    trap '
                        ((${#taskPIDs[@]})) && {
                            kill "${taskPIDs[@]}" 2> /dev/null || true
                            wait "${taskPIDs[@]}" 2> /dev/null || true
                        }
                    ' EXIT

                    # Start Python HTTP Server (MUST support HTTP Range
                    #   Request) to serve ISO.
                    python3 -c "$(cat - 0<<'pyEOF'
import http.server, os, sys, functools, shutil
from datetime import datetime, timezone

class RangeHandler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path): return super().send_head()
        try: f = open(path, 'rb')
        except OSError:
            self.send_error(404); return None
        fs = os.fstat(f.fileno())
        size = fs.st_size
        ctype = self.guess_type(path)
        rng = self.headers.get('Range', '')
        (start, end) = (0, (size - 1))
        if rng.startswith('bytes='):
            try:
                (s, e) = rng[6:].split('-', 1)
                start = int(s) if s else 0
                end = int(e) if e else size - 1
            except ValueError:
                f.close()
                self.send_error(400)
                return None
            end = min(end, (size - 1))
            if (start > end):
                f.close()
                self.send_error(416)
                return None
            f.seek(start)
            self._copy_length = end - start + 1
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        else:
            self._copy_length = None
            self.send_response(200)
        length = end - start + 1
        self.send_header('Content-type', ctype)
        self.send_header('Content-Length', str(length))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Last-Modified', self.date_time_string(fs.st_mtime))
        self.end_headers()
        return f
    def copyfile(self, source, outputfile):
        try:
            remaining = getattr(self, '_copy_length', None)
            if remaining is not None:
                self._copy_length = None
                buf = shutil.COPY_BUFSIZE
                while (remaining > 0):
                    data = source.read(min(buf, remaining))
                    if not data: break
                    outputfile.write(data)
                    remaining -= len(data)
            else: super().copyfile(source, outputfile)
        except (BrokenPipeError, ConnectionResetError): pass
    def log_message(self, fmt, *args):
        hdrs = ''.join(f'  {k}: {v}\n' for k, v in self.headers.items())
        sys.stderr.write(
            f'[{datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}] '
            f'{fmt % args}\n{hdrs}'
        )
        sys.stderr.flush()

http.server.test(
    HandlerClass=functools.partial(
        RangeHandler,
        directory=(sys.argv[2] if len(sys.argv) > 2 else '.'),
    ),
    port=int(sys.argv[1]) if len(sys.argv) > 1 else 8080,
    bind='0.0.0.0',
)
pyEOF
                    )" "${httpSvcPort}" "${_OCP__CLUSTER_DIR}" \
                        1> "${_OCP__CLUSTER_DIR}/ocp--installer--httpd.log" 2>&1 & taskPIDs+=($!)
                    # Start Chisel Reverse Tunnel to expose HTTP Server.
                    {
                        typeset __shOpt="$(shopt -po xtrace)"; set +x
                        chisel client \
                            --auth "${chiselCrdUsr}:${chiselCrdPwd}" \
                            "${_SVC__TUN__CP_URL%%/}/" \
                            "R:0.0.0.0:${_SVC__TUN__DP_PORT}:localhost:${httpSvcPort}" \
                            1> "${_OCP__CLUSTER_DIR}/ocp--installer--chisel.log" 2>&1 & taskPIDs+=($!)
                        eval "${__shOpt}"; unset __shOpt
                    }
                    # Probe ISO URL readiness via Chisel Tunnel.
                    (
                        typeset -i tryLeft=5
                        while ((tryLeft)); do
                            sleep 5
                            curl -fsSL -I -o /dev/null \
                                --connect-timeout 2 --max-time 5 \
                                "${isoURL}" && break
                            ((--tryLeft))
                        done
                    )

                    # Reboot Nodes into OCP Agent Installation ISO.
                    ({
                        typeset bmcURL= bmcVend= bmcSysId= bmcMgrId=
                        typeset diskWipeMethod=
                        typeset -i tryLeft=0 didBMCwipe=0
                        typeset -i myPID="${BASHPID}"
                        typeset -i tPID="$(ps -o ppid= -p "${myPID}")"
                        while IFS= read -r bmcURL; do
                            # Auto-discover BMC Vendor and Identifiers.
                            bmcVend=$(
                                RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET '' |
                                jq -r '.Vendor // "Unknown"'
                            )
                            bmcSysId=$(
                                RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET 'Systems' |
                                jq -r '.Members[0]["@odata.id"] | split("/")[-1]'
                            )
                            bmcMgrId=$(
                                RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET 'Managers' |
                                jq -r '.Members[0]["@odata.id"] | split("/")[-1]'
                            )

                            # Vendor-specific preparation.
                            case ${bmcVend} in
                            (Dell)
                                # Ignore Cert. on `.RFS.1` (VirtualMedia/CD).
                                RedfishAPIcall "${bmcInfo}" "${bmcURL}" PATCH \
                                    "Managers/${bmcMgrId}/Attributes" \
                                    -d '{"Attributes": {"RFS.1.IgnoreCertWarning": "Yes"}}'
                                ;;
                            (*)   false;;
                            esac

                            # Ensure booting to ISO.
# Note:
#   The BMC does not always guarantee booting to ISO. It has been observed the
#   Node can boot to the old OS, despite
#   `BootSourceOverrideEnabled=Continuous`. The `WipeDisks()` implements ISO
#   Boot detection and fails if it detects the Node booted to the old OS, so
#   the entire boot attempt can be retried.
                            tryLeft=5 didBMCwipe=0
                            while ((tryLeft)); do
                                kill -0 "${tPID}" 2>/dev/null || break
                                diskWipeMethod=

                                # Eject previously mounted media.
                                VCD-Eject "${bmcInfo}" "${bmcURL}" "${bmcMgrId}"
                                # Set Boot Order.
                                {
                                    # Try to set to VCD for wiping Disks via Host OS.
                                    RedfishAPIcall "${bmcInfo}" "${bmcURL}" PATCH \
                                        "Systems/${bmcSysId}" \
                                        -d '{"Boot": {
                                            "BootSourceOverrideEnabled": "Continuous",
                                            "BootSourceOverrideTarget": "Cd"
                                        }}' &&
                                    diskWipeMethod=OS
                                } || ((didBMCwipe)) || {
                                    # Fallback to wiping Disks via BMC.
# Note:
#   Currently, we do not have a solution to perform BMC wipe on for Dell BOSS
#   Disk, if it is set as RAID. The BOSS RAID Disk is most likely used as the
#   Boot Disk, hence the above ISO Booting instability issue may still cause
#   the Node to boot to the old OS.
                                    WipeDisks "${tPID}" "${bmcInfo}" \
                                        "${bmcURL}" "${bmcSysId}" "${bmcMgrId}" \
                                        BMC
                                    didBMCwipe=1
                                }
                                # Mount ISO.
                                RedfishAPIcall "${bmcInfo}" "${bmcURL}" POST \
                                    "Managers/${bmcMgrId}/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia" \
                                    -d "$(
                                        jq -cnr \
                                            --arg img "${isoURL}" \
                                            '{
                                                "Image": $img,
                                                "TransferProtocolType": "HTTPS",
                                                "TransferMethod": "Stream"
                                            }'
                                    )"
                                # Set boot `Once` if BMC Wipe (`Continuous` not supported).
                                [ -n "${diskWipeMethod}" ] || {
                                    RedfishAPIcall "${bmcInfo}" "${bmcURL}" PATCH \
                                        "Systems/${bmcSysId}" \
                                        -d '{"Boot": {
                                            "BootSourceOverrideEnabled": "Once",
                                            "BootSourceOverrideTarget": "Cd"
                                        }}'
                                }
                                # Restart Host.
                                Host-PowerControl "${bmcInfo}" "${bmcURL}" "${bmcSysId}" ForceRestart
                                # Wipe Disks via Host OS (Only detect ISO Boot for BMC Wipe).
                                WipeDisks "${tPID}" "${bmcInfo}" \
                                    "${bmcURL}" "${bmcSysId}" "${bmcMgrId}" \
                                    "${diskWipeMethod}" && break
                                ((--tryLeft))
                            done
                            # Restore Boot Order.
                            [ -z "${diskWipeMethod}" ] || {
                                RedfishAPIcall "${bmcInfo}" "${bmcURL}" PATCH \
                                    "Systems/${bmcSysId}" \
                                    -d '{"Boot": {
                                        "BootSourceOverrideEnabled": "Disabled",
                                        "BootSourceOverrideTarget": "None"
                                    }}'
                            }
                        done < <(jq -r '
                            .[] | .url
                        ' 0< "${bmcInfo}")
                    } |& tee "${_OCP__CLUSTER_DIR}/ocp--installer--bmc.log") & taskPIDs+=($!)
                    # Wait for BootStrap Node to finish.
                    (
                        typeset -i tryLeft="${_OCP__INSTLR_WAIT__BOOTSTRAP__TRY}"
                        while ((tryLeft)); do
                            openshift-install agent wait-for bootstrap-complete && break
                            ((--tryLeft))
                        done
                    )

                    # Day-1.5 Phase.
                    (
                        typeset cfgKey= cfgVal=
                        export KUBECONFIG="${_OCP__CLUSTER_DIR}/auth/kubeconfig"
                        while IFS=$'\t' read -r cfgKey cfgVal; do
                            case ${cfgKey} in
                              (NodeProv)
                                [ "${cfgVal}" = false ] && {
                                    # Workers are provisioned by ABI. No
                                    #   BareMetalHost CRDs or Ironic
                                    #   provisioning network.
                                    while true; do
                                        oc -n openshift-machine-api \
                                            scale MachineSets \
                                            --replicas 0 --all \
                                        && break || sleep 60
                                    done
                                }
                                ;;
                            esac
                        done 0< <(
                            yq -o json eval '
                                ."Day1.5".config // []
                            ' "${_OCP__ABI__CFG}" |
                            jq -r '
                                .[] | to_entries[] |
                                [.key, (.value | tostring)] | join("\t")
                            '
                        )
                        true
                    ) & taskPIDs+=($!)
                    # Wait for OCP Installation to complete.
                    (
                        typeset -i tryLeft="${_OCP__INSTLR_WAIT__CLUSTER__TRY}"
                        while ((tryLeft)); do
                            openshift-install agent wait-for install-complete && break
                            ((--tryLeft))
                        done
                    )

                    # Eject Virtual Media on all Nodes.
                    while IFS= read -r bmcURL; do
                        VCD-Eject "${bmcInfo}" "${bmcURL}" "$(
                            RedfishAPIcall "${bmcInfo}" "${bmcURL}" GET 'Managers' |
                            jq -r '.Members[0]["@odata.id"] | split("/")[-1]'
                        )"
                    done < <(jq -r '.[] | .url' 0< "${bmcInfo}")
                )
                cp "${_OCP__CLUSTER_DIR}/auth/kubeconfig" "${kubeCfg}"
                export KUBECONFIG="${kubeCfg}"

                # Update BitWarden.
                [ -z "${_BW__NOTE_NAME__OCP__KCFG}" ] || ( set +x
                    typeset bwAttFilePath="${_OCP__CLUSTER_DIR}/auth/kubeconfig"
                    typeset bwData= bwItemID= e=
                    bw sync
                    bwData="$(bw get item "${_BW__NOTE_NAME__OCP__KCFG}")" || {
                        echo "You may NOT have access to BitWarden Note \`${_BW__NOTE_NAME__OCP__KCFG}\`." 1>&2
                        exit 1
                    }
                    bwItemID="$(jq -cr '.id' 0<<<"${bwData}")"
                    while IFS='' read -r e; do
                        bw delete --itemid "${bwItemID}" attachment "${e}" || {
                            echo "You do NOT have R/W access to BitWarden Note \`${_BW__NOTE_NAME__OCP__KCFG}\`." 1>&2
                            exit 1
                        }
                    done 0< <(jq -r --arg fn "${bwAttFilePath##*/}" '
                        (.attachments // [])[] | select(.fileName == $fn) | .id
                    ' 0<<<"${bwData}")
                    bw create --file "${bwAttFilePath}" --itemid "${bwItemID}" attachment 1> /dev/null
                    bwData="$(jq -r \
                        --arg fn__c 'cred.OCP' \
                        --rawfile fv__c <(
                            jq -cnj \
                                --arg usr kubeadmin \
                                --rawfile pwd <(set +x; printf '%s' "$(0< "${_OCP__CLUSTER_DIR}/auth/kubeadmin-password")") \
                                '{usr: $usr, pwd: $pwd}'
                        ) \
                        '.fields|=((. // []) | (
                            map(select(.name != $fn__c)) +
                            [{name: $fn__c, value: $fv__c, type: 1}]
                        ))' \
                    0< <(bw get item "${_BW__NOTE_NAME__OCP__KCFG}"))"
                    bw encode 0<<<"${bwData}" | bw edit item "${bwItemID}" 1> /dev/null
                true )
            }
            {   # Verification Phase.
                oc wait Nodes --all --for condition=Ready --timeout=300s
                (   # Isolate `SECONDS` reset.
                    # Monitor ClusterOperators readiness.
                    SECONDS=0 wInt=30 wMax=1800     # 30 Min. Max.
                    while ((SECONDS < wMax)); do
                        { oc get ClusterOperators -o json | jq -e '
                            .items | all(
                                .status.conditions |
                                ((.[] | select(.type == "Available")).status == "True")  and
                                ((.[] | select(.type == "Degraded")).status  == "False")
                            )
                        ' 1> /dev/null; } && break
                        sleep ${wInt}
                        echo "Waited ${SECONDS}/${wMax} sec.: "\
'Checking ClusterOperators...' 1>&2
                    done
                    ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'ClusterOperators to be ready.' 1>&2; exit 2; }
                    # Final status.
                    oc get ClusterOperators
                )
            }
            {   # Day-2 Phase.
                iSes=$((_OCP__INSTLR_FLG__CUSTOM & 0x04))
                fCstm=$(((_OCP__INSTLR_FLG__CUSTOM &= ~0x04) & ~0x03))
                while ((fCstm)); do
                    lsb=$((fCstm & -fCstm))
                    case ${lsb} in
                      (32) printf "Day-2 Phase (0x%08x):\n" ${lsb};;&
                      (32)          (   # 0x000020  Executing Custom Day-2 Script.
eval '( set -euxo pipefail; shopt -s inherit_errexit
'"${_OCP__INSTLR_DAY2}"$'\ntrue )'
                      );;
                    esac
                    ((fCstm ^= lsb)) || true
                done
                ((iSes)) && echo 'Manual Day-2 Operation.' &&
                    PROMPT_COMMAND='PS1="${PS1%\[Day-2\] }[Day-2] "' EnterShell
            }
            true
          );;&
          (1|3) # Personal Action.
#           # Do not turn on `set -u` for Interactive Session, due to the
#           #   standard RC files are not properly prepared for it.
#           bash +O expand_aliases -iec "$(cat - 0<<'cmd1EOF'
            bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmd1EOF'
                typeset kubeCfg="${1:-}"; (($#)) && shift
                typeset -f __RelPhyPath 1> /dev/null || {
                    [ -r "${HOME}/.kube/rc/k8s--rc" ] &&
                    . "${HOME}/.kube/rc/k8s--rc"
                }
                typeset e=
                eval "typeset -a rcSrcs=${_RC__SRCS}"
                [ -e "${kubeCfg}" ] ||
                    cp "${_OCP__CLUSTER_DIR}/auth/kubeconfig" "${kubeCfg}"
                mkdir -p -- "${_OCP__CLUSTER_DIR}/rc"
                if ((${#rcSrcs[@]})); then
                    for e in "${rcSrcs[@]}"; do
                        [ -d "${e}" ] && e="$(__RelPhyPath "${_OCP__CLUSTER_DIR}/rc" "${e}")"
                        (
                            cd "${_OCP__CLUSTER_DIR}/rc"
                            find "${e}/" -type f -exec bash -o pipefail -O inherit_errexit -euc "$(
                                cat - 0<<'cmd2EOF'
typeset p='{}' m=
typeset f="${p##*/}"
if [[ "${f}" == *..* ]]; then
    m="${f#*..}"
    m="${m//.//}"
    [[ "${_OCP__CLUSTER_DIR}" == "${m}"* ]] && ln -sf "${p}" "${f%%..*}"
else
    ln -sf "${p}"
fi
true
cmd2EOF
                            )" \;
                        )
                    done
                else
                    touch "${_OCP__CLUSTER_DIR}/rc/k8s--rc"
                fi
                true
cmd1EOF
            )" '' "${kubeCfg}"
            ;;
          (i)   PROMPT_COMMAND='PS1="${PS1%\[ABI-BM\] }[ABI-BM] "' EnterShell 0;;
          (*)   false;;
        esac
        cat - 0<<tailEOF
Please keep the files \`${_OCP__CLUSTER_DIR}/auth/*\` safe, because they are
not recoverable.
It is recommended to use the copy of KUBECONFIG file instead:
    export KUBECONFIG=${kubeCfg@Q}
tailEOF

        true
cmdEOF
    )"; echo $?
```
</details>


## AWS
### Installation
<details><summary>Optional Pre-Installation</summary>

```shell
( set -euo pipefail; shopt -s inherit_errexit
    cpuType=0
    clsName=edttj--tst-1
    dlDestPfx=ocp-install/4.yy
    awsRgn=us-east-1
    baseDom=...dnsBaseDomain...
    case ${cpuType} in
      (0)
        cpuArch=arm64
        wrkNodeType='{}'
        dlURL='https://mirror.openshift.com/pub/openshift-v4/aarch64/clients/ocp/stable/openshift-install-linux-amd64.tar.gz'
        dlDestDir="${dlDestPfx}/arm"
        ;;
      (1)
        cpuArch=amd64
        wrkNodeType='{"aws": {"type": "m6i.metal"}}'
        dlURL='https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-install-linux.tar.gz'
        dlDestDir="${dlDestPfx}/x86"
        ;;
    esac
    pullCrd="$(0< .data/pullSecret)"
    sshKey="$(0< "${HOME}/.ssh/openshift-qe.pub")"

    # Download OCP Installer.
    mkdir -p "${dlDestDir}"
    curl -fsSLo- -z "${dlDestDir}/${dlURL##*/}" -D >(
        exec 3>&1
        {
            ts="$(
                sed -nE \
                    -e '/^HTTP\/[12]\.[01] 304/q1' \
                    -e 's/^\Last-Modified:\s*([^\r]*)\r?/\1/p'
            )" &&
                touch -d "${ts}" "${dlDestDir}/${dlURL##*/}" ||
                tar zc -T /dev/null 1>&3
        } 1>&2
    ) "${dlURL}" | tar zx -C "${dlDestDir}/"
    # Pre-create `install-config.yaml` to avoid interactive Q/A.
    mkdir -p "${k8sClusterDir}"
    {
        yq -p yaml -o json eval . |
        jq \
            --arg baseDom "${baseDom}" \
            --arg clsName "${clsName}" \
            --arg pullCrd "${pullCrd}" \
            --arg sshKey "${sshKey}" \
            --arg cpuArch "${cpuArch}" \
            --argjson wrkNodeType "${wrkNodeType}" \
            --arg awsRgn "${awsRgn}" \
            '
                .baseDomain=$baseDom |
                .metadata.name=$clsName |
                .pullSecret=$pullCrd |
                .sshKey=$sshKey |
                .compute[0]|=(
                    .architecture=$cpuArch |
                    .platform=$wrkNodeType
                ) |
                .platform.aws.region=$awsRgn
            ' |
        yq -p json -o yaml eval .
    } 0<<'fileEOF' 1> "${K8S__CLUSTER_DIR:-.}/install-config.yaml"
apiVersion: v1
baseDomain: ''
compute:
  - architecture: ''
    name: worker
    platform: ''
metadata:
  name: ''
platform:
  aws:
    region: ''
pullSecret: ''
sshKey: ''
fileEOF
true ); echo $?
```
</details>
<details><summary>IPI (Installer-Provisioned Infrastructure)</summary>

Requires [__RelPhyPath()](./00--Libraries.md#Generic).
```shell
# OCP Installation IPI on AWS.
#   Installation Phases:
#     Day-0   Cluster Configuration.
#               Responsible for producing a final `install-config.yaml`. If any
#               customization flag or interactive session is requested, `create
#               install-config` is called (creating or updating the file). Use
#               the custom script and/or interactive session to further modify
#               it, if desired. A pre-created `install-config.yaml`, prior to
#               calling this script, can also serve as the starting point, or
#               be used directly when no flags are set.
#     Day-1   Manifest Customization.
#               Runs `create manifests`, if customization is requested, to
#               generate the full manifest tree under `openshift/`. Use the
#               custom script and/or interactive session to add or modify
#               manifests (e.g. MachineConfig, custom resources), if desired,
#               before the cluster is deployed.
#     Day-2   Post-Deployment Customization.
#               Runs after `create cluster` completes and `KUBECONFIG` is set.
#               Use the custom script and/or interactive session to configure
#               the running cluster (e.g. install operators, apply policies,
#               configure identity providers), if desired.
#   The `_OCP__INSTLR_FLG__CUSTOM` is a bit flag to control phase behaviour.
#     0x00000001    Interactive Session at the end of Day-0 Phase.
#     0x00000002    Interactive Session at the end of Day-1 Phase.
#     0x00000004    Interactive Session at the end of Day-2 Phase.
#       NOTE:   Exiting any of these Sessions with Exit Status 255 will stop
#               the whole Installation procedure.
#     0x00000008    Executing `_OCP__INSTLR_DAY0` during Day-0 Phase.
#     0x00000010    Executing `_OCP__INSTLR_DAY1` during Day-1 Phase.
#     0x00000020    Executing `_OCP__INSTLR_DAY2` during Day-2 Phase.
#       NOTE:   The content of these Env. Var. is executed via
#               `eval "( set -euxo pipefail; shopt -s inherit_errexit;
#               ${_OCP__INSTLR_...}; true )"` (in a sub-shell).
#     0x01000000    Enabling SSM Access for OCP Nodes on AWS.
__SHELL=0 \
    _OCP__INSTLR_ACTION=1 \
    _OCP__INSTLR_FLG__CUSTOM="$((_OCP__INSTLR_FLG__CUSTOM | 0x01000000))" \
    _OCP__INSTLR_LOG_LEVEL=info \
    _OCP__INSTLR_DIR='...ocpInstallerDir...' \
    _OCP__INSTLR_DAY0="${_OCP__INSTLR_DAY0:-: 'Custom Day-0 Script.'}" \
    _OCP__INSTLR_DAY1="${_OCP__INSTLR_DAY1:-: 'Custom Day-1 Script.'}" \
    _OCP__INSTLR_DAY2="${_OCP__INSTLR_DAY2:-: 'Custom Day-2 Script.'}" \
    _OCP__INSTLR_WAIT__CLUSTER__TRY='...numOfTryToWaitForCluster...' \
    _OCP__CLUSTER_DIR='...ocpClusterDir...' \
    _AWS__USE_SSO=0 \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    _BW__NOTE_NAME='...bwNoteName...' \
    _RC__SRCS='(...srcDirsOfRCfiles...)' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    AWS_REGION=us-east-1 \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        {
            if ((_AWS__USE_SSO)); then
                ((_AWS__RESET_PROFILE)) && {
                    # Clean up the AWS CLI profile.
                    sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                    sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
                }
                klist -s || kinit
                aws-saml.py \
                    --region "${AWS_REGION}" \
                    --target-profile "${_AWS__PROFILE}" \
                    --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                    ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
                function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
                export -f aws
            else
                typeset __shOpt="$(shopt -po xtrace)"; set +x
                [ -n "${BW_SESSION}" ] && bw sync || {
                    echo 'You do NOT have an active and sync:ed BitWarden Session!!!' 1>&2
                    exit 1
                }
                eval "$(
                    bw get notes "${_BW__NOTE_NAME}" || {
                        echo "You may NOT have access to BitWarden Note \`${_BW__NOTE_NAME}\`." 1>&2
                        echo false
                    }
                )"
                eval "${__shOpt}"; unset __shOpt
            fi
#           aws configure set aws_access_key_id "${AWS_ACCESS_KEY_ID}" --profile "${_AWS__PROFILE}"
#           aws configure set aws_secret_access_key "${AWS_SECRET_ACCESS_KEY}" --profile "${_AWS__PROFILE}"
            aws configure list --no-cli-pager
#           cat "${AWS_CONFIG_FILE}" "${AWS_SHARED_CREDENTIALS_FILE}"
#           eval "$(aws configure export-credentials --format env)"
            aws sts get-caller-identity --no-cli-pager
        }
        eval "$(
            typeset e1= e2=
            typeset -a a1=() a2=()
            mkdir -p -- "${_OCP__CLUSTER_DIR}"
            for e1 in _OCP__{CLUSTER,INSTLR}_DIR; do
                eval "${e1}=\"\$(CDPATH= cd -L \"\${${e1}}\" && pwd)\""
            done
            for e1 in _RC__SRCS; do
                eval "eval \"a1=\${${e1}}\""
                for e2 in "${a1[@]}"; do
                    eval "a2+=(\"\$(CDPATH= cd -L ${e2@Q} && pwd)\")"
                done
                eval "${e1}=\"(${a2[@]@Q})\""
            done
            typeset -p _OCP__{CLUSTER,INSTLR}_DIR _RC__SRCS
        )"
        typeset -i _OCP__INSTLR_FLG__CUSTOM="${_OCP__INSTLR_FLG__CUSTOM}"
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset kubeCfg="${_OCP__CLUSTER_DIR}/kubecfg"

        function openshift-install () {
            typeset -i es=0
            {
                echo \
"$(date -Iseconds)|${FUNCNAME[0]@Q} ${*@Q}"$'\n'"$(printf '%.0s-' {1..80})"
                "${_OCP__INSTLR_DIR}/openshift-install" \
                    --dir "${_OCP__CLUSTER_DIR}/" \
                    ${_OCP__INSTLR_LOG_LEVEL:+--log-level "${_OCP__INSTLR_LOG_LEVEL}"} \
                    "$@" 2>&1 || es=$?
                echo "$(printf '%.0s=' {1..80})"
                exit ${es}
            } | tee -a "${_OCP__CLUSTER_DIR}/ocp--installer--cluster.log"
            return ${PIPESTATUS[0]}
        }
        function EnterShell () {
            typeset -i asChild="${1:-1}"; (($#)) && shift
            export -f openshift-install
            cd "${_OCP__CLUSTER_DIR}/"
            if ((asChild)); then
                echo \
                    'Exit this interactive session, when you are finished, to' \
                    'continue (Exit Status 255 will cancel the installation).'
                "${SHELL}" || (($? != 255))
                cd - 1> /dev/null
            else
                echo 'Do NOT forget to exit this interactive session!!!'
                exec "${SHELL}"
            fi
            true
        }

        case ${_OCP__INSTLR_ACTION} in
          (-2|0|2)  openshift-install destroy bootstrap || true;;&
          (-2|-1|2) openshift-install destroy cluster || exit 1;;&
          (-2|2)    rm -rf "${_OCP__CLUSTER_DIR}/";;&
          (1|2)     (
            typeset -i iSes=0 fCstm=0 lsb=0
            {   # Preparation Phase.
                rm -f "${_OCP__CLUSTER_DIR}/auth/kubeconfig"
                unset KUBECONFIG
            }
            {   # Day-0 Phase.
                iSes=$((_OCP__INSTLR_FLG__CUSTOM & 0x01))
                fCstm=$(((_OCP__INSTLR_FLG__CUSTOM &= ~0x01) & ~0x03))
                ((fCstm | iSes)) && openshift-install create install-config
                while ((fCstm)); do
                    lsb=$((fCstm & -fCstm))
                    case ${lsb} in
                      (8)   printf "Day-0 Phase (0x%08x):\n" ${lsb};;&
                      (8)           (   # 0x000008  Executing Custom Day-0 Script.
eval '( set -euxo pipefail; shopt -s inherit_errexit
'"${_OCP__INSTLR_DAY0}"$'\ntrue )'
                      );;
                    esac
                    ((fCstm ^= lsb)) || true
                done
                ((iSes)) && echo 'Manual Day-0 Operation.' &&
                    PROMPT_COMMAND='PS1="${PS1%\[Day-0\] }[Day-0] "' EnterShell
            }
            {   # Day-1 Phase.
                iSes=$((_OCP__INSTLR_FLG__CUSTOM & 0x02))
                fCstm=$(((_OCP__INSTLR_FLG__CUSTOM &= ~0x02) & ~0x03))
                ((fCstm | iSes)) && openshift-install create manifests
                while ((fCstm)); do
                    lsb=$((fCstm & -fCstm))
                    case ${lsb} in
                      (16|16777216) printf "Day-1 Phase (0x%08x):\n" ${lsb};;&
                      (16)          (   # 0x000010  Executing Custom Day-1 Script.
eval '( set -euxo pipefail; shopt -s inherit_errexit
'"${_OCP__INSTLR_DAY1}"$'\ntrue )'
                      );;
                      (16777216)    (   # 0x01000000    Enabling SSM Access for OCP Nodes on AWS.
                        typeset e= mcDir="${_OCP__CLUSTER_DIR}/openshift"
                        mkdir -p -- "${mcDir}"
                        # Applying MachineConfig to OCP Nodes.
                        for e in {master,worker}; do
                            cat - 0<<ocEOF 1> "${mcDir}/99999-00--${e}--ssm-agent-install.yaml"
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99999-00--${e}--ssm-agent-install
  labels:
    machineconfiguration.openshift.io/role: ${e}
spec:
  config:
    ignition:
      version: 3.2.0  # Safest value.
    storage: {} # Required empty object
    systemd:
      units:
        - name: aws-ec2--ssm-agent--install.service
          enabled: true
          contents: |
            [Unit]
            Description=Install AWS EC2 SSM Agent
            After=network-online.target
            Wants=network-online.target

            [Service]
            Type=oneshot
            RemainAfterExit=yes
            ExecStart=/usr/bin/sh -c ' \\
                # Determine the correct the architecture string. \\
                typeset arch="\$\$(/usr/bin/uname -m)"; \\
                case \$\${arch} in \\
                  (x86_64)  arch=amd64;; \\
                  (aarch64) arch=arm64;; \\
                esac; \\
                if /usr/bin/rpm -q amazon-ssm-agent; then \\
                    /usr/bin/systemctl enable amazon-ssm-agent.service; \\
                    /usr/bin/systemctl start amazon-ssm-agent.service; \\
                else \\
                    # Remove any broken stub agent if present, ignore if not found. \\
                    /usr/bin/rpm-ostree override remove amazon-ssm-agent || true; \\
                    # Install the agent. \\
                    /usr/bin/rpm-ostree install "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_\$\${arch}/amazon-ssm-agent.rpm"; \\
                    /usr/bin/systemctl reboot; \\
                fi; \\
            '

            [Install]
            WantedBy=multi-user.target
ocEOF
                        done
                      );;
                    esac
                    ((fCstm ^= lsb)) || true
                done
                ((iSes)) && echo 'Manual Day-1 Operation.' &&
                    PROMPT_COMMAND='PS1="${PS1%\[Day-1\] }[Day-1] "' EnterShell
            }
            {   # Deployment Phase.
                (
                    typeset -i tryLeft="${_OCP__INSTLR_WAIT__CLUSTER__TRY}"
                    while ((tryLeft)); do
                        openshift-install create cluster && break
                        ((--tryLeft))
                    done
                )
                cp "${_OCP__CLUSTER_DIR}/auth/kubeconfig" "${kubeCfg}"
                export KUBECONFIG="${kubeCfg}"
            }
            {   # Day-2 Phase.
                iSes=$((_OCP__INSTLR_FLG__CUSTOM & 0x04))
                fCstm=$(((_OCP__INSTLR_FLG__CUSTOM &= ~0x04) & ~0x03))
                while ((fCstm)); do
                    lsb=$((fCstm & -fCstm))
                    case ${lsb} in
                      (32|16777216) printf "Day-2 Phase (0x%08x):\n" ${lsb};;&
                      (32)          (   # 0x000020  Executing Custom Day-2 Script.
eval '( set -euxo pipefail; shopt -s inherit_errexit
'"${_OCP__INSTLR_DAY2}"$'\ntrue )'
                      );;
                      (16777216)    (   # 0x01000000    Enabling SSM Access for OCP Nodes on AWS.
                        typeset e= iamIP= iamRNs=
                        # Adding IAM Permission Policy `AmazonSSMManagedInstanceCore` to the EC2 Instance IAM Role to allow connecting to the VM via SSM.
                        iamRNs="$(
                            for e in $(
                                oc get Nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}'
                            ); do
                                iamIP="$(
                                    aws ec2 describe-instances \
                                        --instance-ids "${e##*/}" \
                                        --output text \
                                        --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn'
                                )"
                                aws iam get-instance-profile \
                                    --instance-profile-name "${iamIP##*/}" \
                                    --output text \
                                    --query 'InstanceProfile.Roles[0].RoleName'
                            done | sort -u
                        )"
                        [ "${iamRNs}" ]
                        for e in ${iamRNs}; do
                            {   # Attached Policy.
                                aws iam list-attached-role-policies \
                                    --role-name "${e}" \
                                    --output text \
                                    --query 'AttachedPolicies[].PolicyName' |
                                grep -qE '^AmazonSSMManagedInstanceCore$'
                            } || aws iam attach-role-policy \
                                --role-name "${e}" \
                                --policy-arn 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'
                        done
                      );;
                    esac
                    ((fCstm ^= lsb)) || true
                done
                ((iSes)) && echo 'Manual Day-2 Operation.' &&
                    PROMPT_COMMAND='PS1="${PS1%\[Day-2\] }[Day-2] "' EnterShell
            }
            true
          );;&
          (1|2|3)   # Personal Action.
#           # Do not turn on `set -u` for Interactive Session, due to the
#           #   standard RC files are not properly prepared for it.
#           bash +O expand_aliases -iec "$(cat - 0<<'cmd1EOF'
            bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmd1EOF'
                typeset kubeCfg="${1:-}"; (($#)) && shift
                typeset -f __RelPhyPath 1> /dev/null || {
                    [ -r "${HOME}/.kube/rc/k8s--rc" ] &&
                    . "${HOME}/.kube/rc/k8s--rc"
                }
                typeset e=
                eval "typeset -a rcSrcs=${_RC__SRCS}"
                [ -e "${kubeCfg}" ] ||
                    cp "${_OCP__CLUSTER_DIR}/auth/kubeconfig" "${kubeCfg}"
                mkdir -p -- "${_OCP__CLUSTER_DIR}/rc"
                if ((${#rcSrcs[@]})); then
                    for e in "${rcSrcs[@]}"; do
                        [ -d "${e}" ] && e="$(__RelPhyPath "${_OCP__CLUSTER_DIR}/rc" "${e}")"
                        (
                            cd "${_OCP__CLUSTER_DIR}/rc"
                            find "${e}/" -type f -exec bash -o pipefail -O inherit_errexit -euc "$(
                                cat - 0<<'cmd2EOF'
typeset p='{}' m=
typeset f="${p##*/}"
if [[ "${f}" == *..* ]]; then
    m="${f#*..}"
    m="${m//.//}"
    [[ "${_OCP__CLUSTER_DIR}" == "${m}"* ]] && ln -sf "${p}" "${f%%..*}"
else
    ln -sf "${p}"
fi
true
cmd2EOF
                            )" \;
                        )
                    done
                else
                    touch "${_OCP__CLUSTER_DIR}/rc/k8s--rc"
                fi
                true
cmd1EOF
            )" '' "${kubeCfg}"
            ;;
          (i)   PROMPT_COMMAND='PS1="${PS1%\[IPI-AWS\] }[IPI-AWS] "' EnterShell 0;;
          (*)   false;;
        esac
        ((_OCP__INSTLR_ACTION < 0)) || cat - 0<<tailEOF
Please keep the files \`${_OCP__CLUSTER_DIR}/auth/*\` safe, because they are
not recoverable.
It is recommended to use the copy of KUBECONFIG file instead:
    export KUBECONFIG=${kubeCfg@Q}
tailEOF

        true
cmdEOF
    )"; echo $?
```
</details>


#### Customization
##### Red Hat OpenShift Virtualization (RH OV)
###### Requirement for Scheduling Virtual Machine Instance (VMI)
<details><summary>Setting `*.metal` Instance Type for Worker Nodes</summary>

```shell
_OCP__INSTLR_FLG__CUSTOM="$((_OCP__INSTLR_FLG__CUSTOM | 0x00000008))"
_OCP__INSTLR_DAY0="${_OCP__INSTLR_DAY0:+${_OCP__INSTLR_DAY0}$'\n'}"$'(\n'"$(cat - 0<<'scrEOF'
: 'Day-0 Customization for RH OV: Worker Nodes need to be `*.metal` Instance Type.'
yq -i eval '.compute[0].platform.aws.type = "m6i.metal"' "${_OCP__CLUSTER_DIR}/install-config.yaml"
true
scrEOF
)"$'\n)'
```
</details>




### Post Installation (Day-2 Operation)
#### Setup for AWS EC2 SSM Access to all Cluster Nodes (OPTIONAL BUT RECOMMENDED), if this has NOT been performed during Installation
<details><summary>Enabling SSM Access for OCP Nodes on AWS (Post-Install)</summary>

```shell
__SHELL=0 \
    _AWS__USE_SSO=0 \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    _BW__NOTE_NAME='note.AWS--IAMuser--OCPinstaller' \
    KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}" \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    AWS_REGION=us-east-1 \
    AWS_ACCOUNT_ID=624914081466 \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        {
            if ((_AWS__USE_SSO)); then
                ((_AWS__RESET_PROFILE)) && {
                    # Clean up the AWS CLI profile.
                    sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                    sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
                }
                klist -s || kinit
                aws-saml.py \
                    --region "${AWS_REGION}" \
                    --target-profile "${_AWS__PROFILE}" \
                    --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                    ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
                function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
                export -f aws
            else
                typeset __shOpt="$(shopt -po xtrace)"; set +x
                [ -n "${BW_SESSION}" ] && bw sync || {
                    echo 'You do NOT have an active and sync:ed BitWarden Session!!!' 1>&2
                    exit 1
                }
                eval "$(
                    bw get notes "${_BW__NOTE_NAME}" || {
                        echo "You may NOT have access to BitWarden Note \`${_BW__NOTE_NAME}\`." 1>&2
                        echo false
                    }
                )"
                eval "${__shOpt}"; unset __shOpt
            fi
#           aws configure set aws_access_key_id "${AWS_ACCESS_KEY_ID}" --profile "${_AWS__PROFILE}"
#           aws configure set aws_secret_access_key "${AWS_SECRET_ACCESS_KEY}" --profile "${_AWS__PROFILE}"
            aws configure list --no-cli-pager
#           cat "${AWS_CONFIG_FILE}" "${AWS_SHARED_CREDENTIALS_FILE}"
#           eval "$(aws configure export-credentials --format env)"
            aws sts get-caller-identity --no-cli-pager
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset e= iamIP= iamRNs=

        # Adding IAM Permission Policy `AmazonSSMManagedInstanceCore` to the EC2 Instance IAM Role to allow connecting to the VM via SSM.
        iamRNs="$(
            for e in $(
                oc get Nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}'
            ); do
                iamIP="$(
                    aws ec2 describe-instances \
                        --instance-ids "${e##*/}" \
                        --output text \
                        --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn'
                )"
                aws iam get-instance-profile \
                    --instance-profile-name "${iamIP##*/}" \
                    --output text \
                    --query 'InstanceProfile.Roles[0].RoleName'
            done | sort -u
        )"
        for e in ${iamRNs}; do
            {   # Attached Policy.
                aws iam list-attached-role-policies \
                    --role-name "${e}" \
                    --output text \
                    --query 'AttachedPolicies[].PolicyName' |
                grep -qE '^AmazonSSMManagedInstanceCore$'
            } || aws iam attach-role-policy \
                --role-name "${e}" \
                --policy-arn 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'
        done

        # Applying MachineConfig to OCP Nodes.
        for e in {master,worker}; do
            oc apply -f - 0<<ocEOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99999-00--${e}--ssm-agent-install
  labels:
    machineconfiguration.openshift.io/role: ${e}
spec:
  config:
    ignition:
      version: $(oc get MachineConfigs -o jsonpath='{range .items[*]}{.spec.config.ignition.version}{"\n"}{end}' | grep -vE '^\$' | head -n 1)
    storage: {} # Required empty object
    systemd:
      units:
        - name: aws-ec2--ssm-agent--install.service
          enabled: true
          contents: |
            [Unit]
            Description=Install AWS EC2 SSM Agent
            After=network-online.target
            Wants=network-online.target

            [Service]
            Type=oneshot
            RemainAfterExit=yes
            ExecStart=/usr/bin/sh -c ' \\
                # Determine the correct the architecture string. \\
                typeset arch="\$\$(/usr/bin/uname -m)"; \\
                case \$\${arch} in \\
                  (x86_64)  arch=amd64;; \\
                  (aarch64) arch=arm64;; \\
                esac; \\
                if /usr/bin/rpm -q amazon-ssm-agent; then \\
                    /usr/bin/systemctl enable amazon-ssm-agent.service; \\
                    /usr/bin/systemctl start amazon-ssm-agent.service; \\
                else \\
                    # Remove any broken stub agent if present, ignore if not found. \\
                    /usr/bin/rpm-ostree override remove amazon-ssm-agent || true; \\
                    # Install the agent. \\
                    /usr/bin/rpm-ostree install "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_\$\${arch}/amazon-ssm-agent.rpm"; \\
                    /usr/bin/systemctl reboot; \\
                fi; \\
            '

            [Install]
            WantedBy=multi-user.target
ocEOF
        done

        true
cmdEOF
    )"; echo $?
# Monitor the MCP Deployment.
( set -euo pipefail; shopt -s inherit_errexit
    function CheckMCPstatus () {
        typeset poolName="${1}"; (($#)) && shift
        typeset poolSign="${1}"; (($#)) && shift
        typeset mcpAction= mcpType= mcpCurState=
        typeset -i i=2 s=0

        while ((i--)); do
            case ${i} in
              (1)   mcpAction=start     mcpType=Updated     ;;
              (0)   mcpAction=finish    mcpType=Updating    ;;
            esac

            echo -n $'\n'"Waiting for MCP ${poolName} pool to ${mcpAction} updating${poolSign}${poolSign}${poolSign}"
            while true; do
                while true; do
                    read -rt 5 mcpCurState; s=$?
                    if {
                        ((s > 128)) ||
                        { ((! s)) && [ "${mcpCurState}" != False ]; }
                    }; then
                        echo -n "${poolSign}"
                    else
                        kill $! 2> /dev/null
                        ((s)) && break || break 2
                    fi
                done 0< <(
                    oc get "MachineConfigPool/${poolName}" \
                        -o jsonpath='{.status.conditions[?(@.type == "'"${mcpType}"'")].status}{"\n"}' --watch
                )
            done
        done
        echo

        true
    }

    CheckMCPstatus worker ':' &
    sleep 3
    CheckMCPstatus master '.'
    wait

    oc get MachineConfigPools
true ); echo $?
# Manual monitoring.
oc get Nodes,MachineConfigPools,MachineConfigs
# Reboot MCP if it stuck.
oc adm reboot-machine-config-pool MachineConfigPool/{master,worker}
# Check the MCO logs.
oc -n openshift-machine-config-operator logs -f "$(oc -n openshift-machine-config-operator get pods -l 'k8s-app=machine-config-controller' -o name)"
# Delete MCs:
oc delete MachineConfig/99999-00--{master,worker}--ssm-agent-install
```
</details>

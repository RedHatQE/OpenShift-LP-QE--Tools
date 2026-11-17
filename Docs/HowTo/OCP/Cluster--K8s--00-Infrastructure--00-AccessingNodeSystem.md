# Cluster -- Kubernetes -- Infrastructure -- Accessing Node System
## Libraries
### Select Nodes
<details><summary>Bare Metal</summary>

```shell
function _k8s--infra-bm--GetNodes () {
    typeset -i nodeRole="${1:-0}"; (($#)) && shift
    typeset -i single="${1:-0}"; (($#)) && shift

    typeset nodeSelector=
    typeset fltCmd='| fzf --header "Select Node(s)." -m'

    ((nodeRole < 0)) && {
        fltCmd=; ((nodeRole = -nodeRole))
    } || {
        ((single)) && fltCmd='| fzf --header "Select a Node."'
    }
    case ${nodeRole} in
      (1)   nodeSelector='-l node-role.kubernetes.io/master';;
      (2)   nodeSelector='-l node-role.kubernetes.io/worker';;
    esac

    eval "$(cat - 0<<cmdEOF
        {
#           echo -e 'NAME\\tROLES'
            kubectl get Nodes --no-headers ${nodeSelector} |
            awk '{print \$1 "\\t" \$3}' |
            sort -k 1,1 -t \$'\\t'
        } | column -ts \$'\\t' ${fltCmd} | sed -E 's/\\s+\\S+\$//'
cmdEOF
    )"

    return 0
}
```
</details>
<details><summary>AWS</summary>

```shell
function _k8s--infra-aws--GetNodes () {
    typeset -i nodeRole="${1:-0}"; (($#)) && shift
    typeset -i single="${1:-0}"; (($#)) && shift

    typeset nodeSelector=
    typeset fltCmd='| fzf --header "Select Node(s)." -m'

    ((nodeRole < 0)) && {
        fltCmd=; ((nodeRole = -nodeRole))
    } || {
        ((single)) && fltCmd='| fzf --header "Select a Node."'
    }
    case ${nodeRole} in
      (1)   nodeSelector='-l node-role.kubernetes.io/master';;
      (2)   nodeSelector='-l node-role.kubernetes.io/worker';;
    esac

    eval "$(cat - 0<<cmdEOF
            {
#           echo -e 'NAME\\tROLES\\tAWS EC2 VM INSTANCE ID'
            join -t \$'\\t' -1 1 -2 1 -o 1.1,1.2,2.2 \\
                <(
                    kubectl get Nodes --no-headers ${nodeSelector} |
                    awk '{print \$1 "\\t" \$3}' | sort -k 1,1 -t \$'\\t'
                ) <(
                    kubectl get Nodes ${nodeSelector} \\
                        -o jsonpath='{range .items[*]}{.metadata.name}{"\\t"}{.spec.providerID}{"\\n"}{end}' |
                    awk '{split(\$2,a,"/"); print \$1 "\\t" a[5]}' |
                    sort -k 1,1 -t \$'\\t'
                )
        } | column -ts \$'\\t' ${fltCmd} | sed -E 's/^(\\S+\\s+){2}//'
cmdEOF
    )"

    return 0
}
```
</details>



## Functions
### Shell Access
<details><summary>Bare Metal</summary>

```shell
function k8s--infra-bm--node--con () {
    typeset usrName="${1:-${K8S__SSH__USR:-core}}"; (($#)) && shift
    typeset -a nodeIDs="${1:-$(_k8s--infra-bm--GetNodes)}"; (($#)) && shift;
    typeset sshOpts="${1:-${K8S__SSH__OPTS:-()}}"; (($#)) && shift

    typeset e= tty=
    typeset -a sshOpts="${sshOpts}"

    usrName="${usrName:+${usrName@Q}}"
    IFS=$'\n' read -d '' -ra nodeIDs 0<<<"${nodeIDs[0]}"
    (($#)) || tty=-t

    for e in "${nodeIDs[@]}"; do
        eval "
            ssh ${tty} \
                -o LogLevel=ERROR \
                -o UserKnownHostsFile=/dev/null \
                -o StrictHostKeyChecking=no \
                ${K8S__SSH__ID:+-i ${K8S__SSH__ID@Q}} \
                ${usrName:+-o User=${usrName@Q}} \
                ${sshOpts[@]@Q} \
                \"\${e}\" ${@@Q}
        "
    done

    return 0
}
```
</details>
<details><summary>AWS</summary>
<details><summary>Normal Console</summary>

Requires [__RandomFreePort()](./00--Libraries.md#Generic) and [__ValidatePortFwds()](./00--Libraries.md#Generic).
```shell
function k8s--infra-aws--node--con () {
    typeset pFwd="${1:-${K8S__SSH__PORT:-$(
        __RandomFreePort 10000 10999
    ):22}}"; (($#)) && shift
    typeset usrName="${1:-${K8S__SSH__USR:-core}}"; (($#)) && shift
    typeset -a nodeIDs="${1:-$(_k8s--infra-aws--GetNodes)}"; (($#)) && shift;
    typeset ssmStartSesOpts="${1:-${K8S__AWS__SSM_STARTSES_OPTS-()}}"; (($#)) && shift

    typeset e=
    typeset -i i=0 awsPID=0 ssmPID=0
    typeset -i lPort="${pFwd%%:*}" rPort="${pFwd##*:}"
    typeset -a ssmStartSesOpts="${ssmStartSesOpts}"

    usrName="${usrName:+${usrName@Q}}"
    IFS=$'\n' read -d '' -ra nodeIDs 0<<<"${nodeIDs[0]}"

    if ((lPort)); then
        typeset sshOpts="${1:-${K8S__SSH__OPTS:-()}}"; (($#)) && shift

        typeset tty=
        typeset -a sshOpts="${sshOpts}"

        __ValidatePortFwds ${lPort} 1 ${rPort} || return 1
        (($#)) || tty=-t

        for e in "${nodeIDs[@]}"; do
            (   # Silence the Job Control messages and allow `trap`.
                eval "
                    aws ssm start-session \
                        --target ${e@Q} \
                        --document-name 'AWS-StartPortForwardingSession' \
                        --parameters 'portNumber=${rPort},localPortNumber=${lPort}' \
                        ${ssmStartSesOpts[@]@Q} 1> /dev/null & awsPID=\$!
                "
                i=15
                while {
                    ((i--)) &&
                    ! nc -zw 1 localhost ${lPort} 2> /dev/null;
                }; do sleep 1; done
                ssmPID="$(pgrep -P ${awsPID})" || exit
                # The SSM Session use SIGINT for graceful exit.
                trap 'kill -s INT ${ssmPID} 2> /dev/null; wait ${awsPID}' EXIT
                eval "
                    ssh -p ${lPort} ${tty} \
                        -o LogLevel=ERROR \
                        -o UserKnownHostsFile=/dev/null \
                        -o StrictHostKeyChecking=no \
                        ${K8S__SSH__ID:+-i ${K8S__SSH__ID@Q}} \
                        ${usrName:+-o User=${usrName@Q}} \
                        ${sshOpts[@]@Q} \
                        localhost ${@@Q}
                "
            )
        done
    else
        typeset ssmCmdTail=

        (($#)) && {
            [ -z "${1}" ] && {
                shift   # Using SSM User.
                (($#)) && {
                    [ -z "${1}" ] &&
                        ssmCmdTail="${ssmStartSesOpts[@]@Q}" || # Bare Session.
                        ssmCmdTail="\
                            --document-name 'AWS-StartInteractiveCommand' \
                            --parameters \"\$(
                                jq -cn --arg c \"\$(echo \"\${@@Q}\")\" \
                                    '{\"command\": [\$c]}'
                            )\" \
                            ${ssmStartSesOpts[@]@Q}
                        "   # Non-Interactive Session.
                } || ssmCmdTail="\
                    --document-name 'AWS-StartInteractiveCommand' \
                    --parameters \"\$(
                        jq -cn --arg c \"/bin/sh -c '\"\${SHELL}\" -l'\" \
                            '{\"command\": [\$c]}'
                    )\" \
                    ${ssmStartSesOpts[@]@Q}
                "   # Interactive Session.
            } || ssmCmdTail="\
                --document-name 'AWS-StartInteractiveCommand' \
                --parameters \"\$(
                    typeset c=\"\${@@Q}\"
                    jq -cn \
                        --arg c 'sudo su -c '\"\${c@Q}\"' - \"\$(\
                            id -un '\"\${usrName}\"'\
                        )\"' \
                        '{\"command\": [\$c]}'
                )\" \
                ${ssmStartSesOpts[@]@Q}
            "   # Non-Interactive Session.
        } || ssmCmdTail="\
            --document-name 'AWS-StartInteractiveCommand' \
            --parameters \"\$(
                jq -cn \
                    --arg c 'sudo su - \"\$(id -un '\"\${usrName}\"')\"' \
                    '{\"command\": [\$c]}'
            )\" \
            ${ssmStartSesOpts[@]@Q}
        "   # Interactive Session.

        for e in "${nodeIDs[@]}"; do
            eval "aws ssm start-session --target ${e@Q} ${ssmCmdTail}"
        done
    fi

    return 0
}
```
</details>
<details><summary>Serial Console</summary>

```shell
function k8s--infra-aws--node--ser () {
    typeset -a nodeIDs="${1:-$(_k8s--infra-aws--GetNodes)}"; (($#)) && shift;
    typeset sshKey="${1:-${K8S__SSH__KEY:-}}"; (($#)) && shift
    typeset sshOpts="${1:-${K8S__SSH__OPTS:-()}}"; (($#)) && shift

    typeset e=
    typeset -i disSCaccess=0
    typeset -a sshOpts="${sshOpts}"

    typeset rgnID="$(
        aws ec2 describe-instances \
            --instance-ids i-0cd196e6231aa6c8d \
            --output text \
            --query "Reservations[*].Instances[*].Placement.AvailabilityZone" \
    )"; rgnID="${rgnID%?}"

    IFS=$'\n' read -d '' -ra nodeIDs 0<<<"${nodeIDs[0]}"

    [ "$(
        aws ec2 get-serial-console-access-status \
            --output text --query 'SerialConsoleAccessEnabled'
    )" != True  ] && {
        aws ec2 enable-serial-console-access 1> /dev/null
        disSCaccess=1
    }
    for e in "${nodeIDs[@]}"; do
        [ "$(
            aws ec2-instance-connect send-serial-console-ssh-public-key \
                --instance-id "${e}" \
                --ssh-public-key "file://${sshKey}" \
                --output text --query 'Success'
        )" = True ] &&
        echo 'To terminate the Serial Console type `[ENTER]~.`.' &&
        eval "
            ssh \
                -o LogLevel=ERROR \
                -o UserKnownHostsFile=/dev/null \
                -o StrictHostKeyChecking=no \
                ${K8S__SSH__ID:+-i ${K8S__SSH__ID@Q}} \
                ${sshOpts[@]@Q} \
                ${e@Q}.port0@serial-console.ec2-instance-connect.${rgnID@Q}.aws
        "
    done
    ((disSCaccess)) && aws ec2 disable-serial-console-access 1> /dev/null

    return 0
}
```
</details>
</details>


### File Transfer
<details><summary>Bare Metal</summary>

```shell
function k8s--infra-bm--node--scp () {
    typeset sPaths="${1}"; (($#)) && shift
    typeset tPath="${1}"; (($#)) && shift
    typeset usrName="${1:-${K8S__SSH__USR:-core}}"; (($#)) && shift
    typeset -a nodeIDs="${1:-$(_k8s--infra-bm--GetNodes)}"; (($#)) && shift;
    typeset scpOpts="${1:-${K8S__SCP__OPTS:-()}}"; (($#)) && shift

    typeset e= tP=
    typeset -i i=0
    typeset -a sPaths="${sPaths}" sPs=()
    typeset -a scpOpts="${scpOpts}"

    usrName="${usrName:+${usrName@Q}}"
    IFS=$'\n' read -d '' -ra nodeIDs 0<<<"${nodeIDs[0]}"

    for e in "${nodeIDs[@]}"; do
        sPs=("${sPaths[@]}")
        for i in "${!sPs[@]}"; do
            [ "${sPs[${i}]:0:1}" = ':' ] &&
            sPs[${i}]="${e}${sPs[${i}]}"
        done
        [ "${tPath:0:1}" = ':' ] && tP="${e}${tPath}" || tP="${tPath}"

        eval "
            scp \
                -o LogLevel=ERROR \
                -o UserKnownHostsFile=/dev/null \
                -o StrictHostKeyChecking=no \
                ${K8S__SSH__ID:+-i ${K8S__SSH__ID@Q}} \
                ${usrName:+-o User=${usrName@Q}} \
                ${scpOpts[@]@Q} \
                ${sPs[@]@Q} ${tP@Q}
        "
    done

    return 0
}
```
</details>
<details><summary>AWS</summary>

Requires [__RandomFreePort()](./00-Libraries.md#Generic) and [__ValidatePortFwds()](./00-Libraries.md#Generic).
```shell
function k8s--infra-aws--node--scp () {
    typeset sPaths="${1}"; (($#)) && shift
    typeset tPath="${1}"; (($#)) && shift
    typeset pFwd="${1:-${K8S__SCP__PORT:-$(
        __RandomFreePort 10000 10999
    ):22}}"; (($#)) && shift
    typeset usrName="${1:-${K8S__SSH__USR:-core}}"; (($#)) && shift
    typeset -a nodeIDs="${1:-$(_k8s--infra-aws--GetNodes)}"; (($#)) && shift;
    typeset ssmStartSesOpts="${1:-${K8S__AWS__SSM_STARTSES_OPTS-()}}"; (($#)) && shift
    typeset scpOpts="${1:-${K8S__SCP__OPTS:-()}}"; (($#)) && shift

    typeset e= tP=
    typeset -i i=0 awsPID=0 ssmPID=0
    typeset -i lPort="${pFwd%%:*}" rPort="${pFwd##*:}"
    typeset -a sPaths="${sPaths}" sPs=()
    typeset -a ssmStartSesOpts="${ssmStartSesOpts}"
    typeset -a scpOpts="${scpOpts}"

    sPs=("${sPaths[@]}")
    for i in "${!sPs[@]}"; do
        [ "${sPs[${i}]:0:1}" = ':' ] &&
        sPs[${i}]="localhost${sPs[${i}]}"
    done
    [ "${tPath:0:1}" = ':' ] && tP="localhost${tPath}" || tP="${tPath}"
    usrName="${usrName:+${usrName@Q}}"
    IFS=$'\n' read -d '' -ra nodeIDs 0<<<"${nodeIDs[0]}"
    __ValidatePortFwds ${lPort} 1 ${rPort} || return 1

    for e in "${nodeIDs[@]}"; do
        (   # Silence the Job Control messages and allow `trap`.
            eval "
                aws ssm start-session \
                    --target ${e@Q} \
                    --document-name 'AWS-StartPortForwardingSession' \
                    --parameters 'portNumber=${rPort},localPortNumber=${lPort}' \
                    ${ssmStartSesOpts[@]@Q} 1> /dev/null & awsPID=\$!
            "
            i=15
            while {
                ((i--)) &&
                ! nc -zw 1 localhost ${lPort} 2> /dev/null;
            }; do sleep 1; done
            ssmPID="$(pgrep -P ${awsPID})" || exit
            # The SSM Session use SIGINT for graceful exit.
            trap 'kill -s INT ${ssmPID} 2> /dev/null; wait ${awsPID}' EXIT
            eval "
                scp -P ${lPort} \
                    -o LogLevel=ERROR \
                    -o UserKnownHostsFile=/dev/null \
                    -o StrictHostKeyChecking=no \
                    ${K8S__SSH__ID:+-i ${K8S__SSH__ID@Q}} \
                    ${usrName:+-o User=${usrName@Q}} \
                    ${scpOpts[@]@Q} \
                    ${sPs[@]@Q} ${tP@Q}
            "
        )
    done

    return 0
}
```
</details>


### TCP Port Fowarding
<details><summary>Bare Metal</summary>

Requires [__RandomFreePort()](./00-Libraries.md#Generic) and [__ValidatePortFwds()](./00-Libraries.md#Generic).
```shell
function k8s--infra-bm--node--port-fwd () {
    typeset pFwd="${1}"; (($#)) && shift
    typeset usrName="${1:-${K8S__SSH__USR:-core}}"; (($#)) && shift
    typeset -a nodeIDs="${1:-$(_k8s--infra-bm--GetNodes)}"; (($#)) && shift;
    typeset sshOpts="${1:-${K8S__SSH__OPTS:-()}}"; (($#)) && shift

    typeset e=
    typeset -i i=0 j=0
    typeset -i lPort="${pFwd%%:*}" rPort="${pFwd##*:}"
    typeset -a sshOpts="${sshOpts}"
    typeset -ai fwdrPIDs=()

    ((lPort)) || lPort="$(__RandomFreePort 10000 10999)"
    usrName="${usrName:+${usrName@Q}}"
    IFS=$'\n' read -d '' -ra nodeIDs 0<<<"${nodeIDs[0]}"
    __ValidatePortFwds ${lPort} ${#nodeIDs[@]} ${rPort} || return 1

    (   # Silence the Job Control messages and allow `trap`.
        for e in "${nodeIDs[@]}"; do
            eval "
                ssh \
                    -o LogLevel=ERROR \
                    -o UserKnownHostsFile=/dev/null \
                    -o StrictHostKeyChecking=no \
                    -NL \"${lPort}:\${e}:${rPort}\" \
                    ${K8S__SSH__ID:+-i ${K8S__SSH__ID@Q}} \
                    ${usrName:+-o User=${usrName@Q}} \
                    ${sshOpts[@]@Q} \
                    \"\${e}\" & fwdrPIDs+=(\$!)
            "
            echo "TCP Local Port $((lPort++)) is forwarded to Remote Port ${rPort}."
        done
        trap 'kill ${fwdrPIDs[@]} 2> /dev/null; wait ${fwdrPIDs[@]}' EXIT
        wait ${fwdrPIDs[@]}
    )

    return 0
}
```
</details>
<details><summary>AWS</summary>

Requires [__RandomFreePort()](./00-Libraries.md#Generic) and [__ValidatePortFwds()](./00-Libraries.md#Generic).
```shell
function k8s--infra-aws--node--port-fwd () {
    typeset pFwd="${1}"; (($#)) && shift
    typeset -a nodeIDs="${1:-$(_k8s--infra-aws--GetNodes)}"; (($#)) && shift;
    typeset ssmStartSesOpts="${1:-${K8S__AWS__SSM_STARTSES_OPTS-()}}"; (($#)) && shift

    typeset e=
    typeset -i i=0 j=0 awsPID=0 ssmPID=0
    typeset -i lPort="${pFwd%%:*}" rPort="${pFwd##*:}"
    typeset -a ssmStartSesOpts="${ssmStartSesOpts}"
    typeset -ai fwdrPIDs=()

    ((lPort)) || lPort="$(__RandomFreePort 10000 10999)"
    IFS=$'\n' read -d '' -ra nodeIDs 0<<<"${nodeIDs[0]}"
    __ValidatePortFwds ${lPort} ${#nodeIDs[@]} ${rPort} || return 1

    (   # Silence the Job Control messages and allow `trap`.
        for e in "${nodeIDs[@]}"; do
            (   # Silence the Job Control messages and allow `trap`.
                shopt -s expand_aliases # A forked sub-shell is non-interactive.
                eval "
                    aws ssm start-session \
                        --target ${e@Q} \
                        --document-name 'AWS-StartPortForwardingSession' \
                        --parameters 'portNumber=${rPort},localPortNumber=${lPort}' \
                        ${ssmStartSesOpts[@]@Q} 1> /dev/null & awsPID=\$!
                "
                i=15
                while {
                    ((i--)) &&
                    ! nc -zw 1 localhost ${lPort} 2> /dev/null;
                }; do sleep 1; done
                ssmPID="$(pgrep -P ${awsPID})" || exit
                # The SSM Session use SIGINT for graceful exit.
                trap 'kill -s INT ${ssmPID} 2> /dev/null; wait ${awsPID}' EXIT
                wait ${awsPID}
            ) & fwdrPIDs+=($!)
            echo "TCP Local Port $((lPort++)) is forwarded to Remote Port ${rPort}."
        done
        trap 'kill ${fwdrPIDs[@]} 2> /dev/null; wait ${fwdrPIDs[@]}' EXIT
        wait ${fwdrPIDs[@]}
    )

    return 0
}
```
</details>


### Remote Execution (Asyncronous)
<details><summary>AWS</summary>

```shell
function k8s--infra-aws--node--cmd () {
    typeset -a nodeIDs="${1:-$(_k8s--infra-aws--GetNodes)}"; (($#)) && shift;
    typeset ssmSendCmdOpts="${1:-${K8S__AWS__SSM_SENDCMD_OPTS:-()}}"; (($#)) && shift

    (($#)) || return 1

    typeset e= cmdID= cmdStat=
    typeset -a ssmSendCmdOpts="${ssmSendCmdOpts}"

    IFS=$'\n' read -d '' -ra nodeIDs 0<<<"${nodeIDs[0]}"

    for e in "${nodeIDs[@]}"; do
        cmdID="$(
            eval "
                aws ssm send-command \
                    --targets 'Key=instanceids,Values='${e@Q} \
                    --document-name 'AWS-RunShellScript' \
                    --parameters "'"$(
                        jq -cn --args "{\"commands\": \$ARGS.positional}" -- "$@"
                    )"'" \
                    --output text --query 'Command.CommandId'
                    ${ssmSendCmdOpts[@]@Q}
                "
        )"

        while true; do
            cmdStat="$(
                aws ssm get-command-invocation \
                    --command-id "${cmdID}" --instance-id "${e}" \
                    --output text --query 'Status'
            )"
            [ "${cmdStat}" = InProgress ] || break
            echo "${cmdStat}"
            sleep 2
        done
        cmdStat="$(
            aws ssm get-command-invocation \
                --command-id "${cmdID}" --instance-id "${e}"
        )"

        echo "Command Invocation: ${cmdID} - $(
            echo "${cmdStat}" | jq -r '"\(.Status) - \(.ResponseCode)"'
        )"
        echo "STDIN : $(
            aws ssm list-commands \
                --command-id "${cmdID}" \
                --query 'Commands[0].Parameters.commands[]' |
            jq -r '.[]'
        )"
        echo "STDOUT: $(echo "${cmdStat}" | jq -r '.StandardOutputContent')"
        echo "STDERR: $(echo "${cmdStat}" | jq -r '.StandardErrorContent')"
    done

    return 0
}
```
</details>

# Cluster -- OpenShift -- Operator -- Layered Product -- Virtualization
## References
<details><summary>Red Hat OpenShift Virtualization</summary>

[TBD](https://)
</details>


## Libraries
### Virtual Machine Instance
<details><summary>Get VMI Information</summary>

```shell
function _olp--virt--infra--VMIsInfo () {
    typeset -i single="${1:-0}"; (($#)) && shift

    typeset fltCmd='| fzf --header "Select VMI(s)." -m'

    ((single)) && fltCmd='| fzf --header "Select a VMI."'
    eval "$(cat - 0<<cmdEOF
        {
#           echo -e 'NAMESPACE\\tVMI\\tIPs(primIP|MAC|IPaddr...;...)'
            oc get VirtualMachineInstances \$(
                oc auth can-i \
                    list VirtualMachineInstances -A 1> /dev/null 2>&1 &&
                printf -- '-A'
            ) -o json |
            jq -r '
                .items[] |
                select(.status.phase == "Running") |
                (
                    .status.interfaces |
                    map(select(.ipAddress)) |
                    map(
                        "\\(.ipAddress)|\\(.mac)|\\(.ipAddresses | join(","))"
                    ) |
                    join(";")
                ) as \$IPs |
                select(\$IPs != "") |
                "\\(.metadata.namespace)\\t\\(.metadata.name)\\t" +
                "\\(.status.nodeName)\\t\\(\$IPs)"
            ' |
            sort -k 1,1 -k 2,2 -t \$'\\t'
        } | column -ts \$'\\t' ${fltCmd}
cmdEOF
    )"

    return 0
}
```
</details>
<details><summary>Select VMI</summary>

```shell
function _olp--virt--infra--GetVMIs () {
    typeset -i single="${1:-0}"; (($#)) && shift

    _olp--virt--infra--VMIsInfo ${single} |
        sed -E 's|^(\S+)\s+(\S+).+|-n "\1" "\2"|'

    return 0
}
```
</details>



## Functions
### Shell Access
<details><summary>VMI</summary>

```shell
function olp--virt--infr--VMI--con () {
    typeset pFwd="${1:-${OLP__VIRT__SSH__PORT:-1:22}}"; (($#)) && shift
    typeset usrName="${1:-${OLP__VIRT__SSH__USR:-}}"; (($#)) && shift
    typeset -a vmiIDs="${1:-$(_olp--virt--infra--GetVMIs)}"; (($#)) && shift;

    typeset e=
    typeset -i lPort="${pFwd%%:*}" rPort="${pFwd##*:}"

    vmiIDs[0]="$(echo "${vmiIDs[0]}" | sed -E 's|" "|" "vmi/|g')"
    IFS=$'\n' read -d '' -ra vmiIDs 0<<<"${vmiIDs[0]}"

    if ((rPort)); then
        if ((lPort)); then
            typeset vctlPortFwdOpts="${1:-${OLP__VIRT__VCTL_PORTFWD_OPTS:-()}}"; (($#)) && shift
            typeset sshOpts="${1:-${K8S__SSH__OPTS:-()}}"; (($#)) && shift

            typeset -a vctlPortFwdOpts="${vctlPortFwdOpts}"
            typeset -a sshOpts="${sshOpts}"

            usrName="${usrName:+${usrName@Q}}"

            for e in "${vmiIDs[@]}"; do
                eval "
                    ssh -t -p ${rPort} \
                        -o LogLevel=ERROR \
                        -o UserKnownHostsFile=/dev/null \
                        -o StrictHostKeyChecking=no \
                        ${K8S__SSH__ID:+-i ${K8S__SSH__ID@Q}} \
                        -o \"\$(
echo 'ProxyCommand=virtctl port-forward --stdio=true ${e} \"%p\"'\
    \"\${vctlPortFwdOpts[@]@Q}\" \
                        )\" \
                        ${usrName:+-o User=${usrName@Q}} \
                        ${sshOpts[@]@Q} \
                        "$(
                            echo "${e}" |
                            sed -E 's|^-n "([^"]+)" "([^"]+)"|\2.\1|'
                        )" ${@@Q}
                "
            done
        else
            typeset vctlSshOpts="${1:-${OLP__VIRT__VCTL_SSH_OPTS:-()}}"; (($#)) && shift
            typeset sshOpts="${1:-${K8S__SSH__OPTS:-()}}"; (($#)) && shift

            typeset -a vctlSshOpts="${vctlSshOpts}"
            typeset -a sshOpts="${sshOpts}"

            [ -n "${usrName}" ] && vctlSshOpts+=(-l "${usrName}")
            (($#)) && vctlSshOpts+=(-c "${1}")

            for e in "${vmiIDs[@]}"; do
                eval "
                    virtctl ssh -p "${rPort}" \
                        ${K8S__SSH__ID:+-i ${K8S__SSH__ID@Q}} \
                        -t '-t' \
                        -t '-o LogLevel=ERROR' \
                        -t '-o UserKnownHostsFile=/dev/null' \
                        -t '-o StrictHostKeyChecking=no' \
                        $(for e in "${sshOpts[@]}"; do echo -n "-t ${e@Q} "; done) \
                        ${e} ${vctlSshOpts[@]@Q}
                "
            done
        fi
    else
        typeset vctlConOpts="${1:-${OLP__VIRT__VCTL_CON_OPTS:-()}}"; (($#)) && shift

        typeset -a vctlConOpts="${vctlConOpts}"

        for e in "${vmiIDs[@]}"; do
            eval "virtctl console ${e/\" \"vmi\//\" \"} ${vctlConOpts[@]@Q}"
        done
    fi

    return 0
}
```
</details>


### File Transfer
<details><summary>VMI</summary>

```shell
function olp--virt--infr--VMI--scp () {
    typeset sPaths="${1}"; (($#)) && shift
    typeset tPath="${1}"; (($#)) && shift
    typeset pFwd="${1:-${OLP__VIRT__SCP__PORT:-1:22}}"; (($#)) && shift
    typeset usrName="${1:-${OLP__VIRT__SSH__USR:-}}"; (($#)) && shift
    typeset -a vmiIDs="${1:-$(_olp--virt--infra--GetVMIs)}"; (($#)) && shift;
    typeset vctlPortFwdOpts="${1:-${OLP__VIRT__VCTL_PORTFWD_OPTS:-()}}"; (($#)) && shift
    typeset scpOpts="${1:-${K8S__SCP_OPTS:-()}}"; (($#)) && shift

    typeset e= v= tP=
    typeset -i i=0
    typeset -i lPort="${pFwd%%:*}" rPort="${pFwd##*:}"
    typeset -a sPaths="${sPaths}" sPs=()
    typeset -a vctlPortFwdOpts="${vctlPortFwdOpts}"
    typeset -a scpOpts="${scpOpts}"

    usrName="${usrName:+${usrName@Q}}"
    vmiIDs[0]="$(echo "${vmiIDs[0]}" | sed -E 's|" "|" "vmi/|g')"
    IFS=$'\n' read -d '' -ra vmiIDs 0<<<"${vmiIDs[0]}"

    for e in "${vmiIDs[@]}"; do
        v="$(echo "${e}" | sed -E 's|^-n "([^"]+)" "vmi/([^"]+)"|\2.\1|')"
        sPs=("${sPaths[@]}")
        for i in "${!sPs[@]}"; do
            [ "${sPs[${i}]:0:1}" = ':' ] &&
            sPs[${i}]="${v}${sPs[${i}]}"
        done
        [ "${tPath:0:1}" = ':' ] && tP="${v}${tPath}" || tP="${tPath}"

        eval "
            scp -P ${rPort} \
                -o LogLevel=ERROR \
                -o UserKnownHostsFile=/dev/null \
                -o StrictHostKeyChecking=no \
                ${K8S__SSH__ID:+-i ${K8S__SSH__ID@Q}} \
                -o \"\$(
echo 'ProxyCommand=virtctl port-forward --stdio=true ${e} \"%p\"'\
    \"\${vctlPortFwdOpts[@]@Q}\" \
                )\" \
                ${usrName:+-o User=${usrName@Q}} \
                ${sshOpts[@]@Q} \
                ${sPs[@]@Q} ${tP@Q}
        "
    done

    return 0
}
```
</details>


### TCP Port Forwarding
<details><summary>VMI</summary>

Requires [__RandomFreePort()](./00--Libraries.md#Generic) and [__ValidatePortFwds()](./00--Libraries.md#Generic).
```shell
function olp--virt--infr--VMI--port-fwd () {
    typeset pFwd="${1:-${OLP__VIRT__PORTFWD__PORT:-1:22}}"; (($#)) && shift
    typeset usrName="${1:-${OLP__VIRT__SSH__USR:-}}"; (($#)) && shift
    typeset -a vmiIDs="${1:-$(_olp--virt--infra--GetVMIs)}"; (($#)) && shift;
    typeset vctlPortFwdOpts="${1:-${OLP__VIRT__VCTL_PORTFWD_OPTS:-()}}"; (($#)) && shift
    typeset sshOpts="${1:-${K8S__SSH__OPTS:-()}}"; (($#)) && shift

    typeset e= v=
    typeset -i i=0
    typeset -i lPort="${pFwd%%:*}" rPort="${pFwd##*:}"
    typeset -a vctlPortFwdOpts="${vctlPortFwdOpts}"
    typeset -a sshOpts="${sshOpts}"
    typeset -ai fwdrPIDs=()

    ((lPort)) || lPort="$(__RandomFreePort 10000 10999)"
    usrName="${usrName:+${usrName@Q}}"
    vmiIDs[0]="$(echo "${vmiIDs[0]}" | sed -E 's|" "|" "vmi/|g')"
    IFS=$'\n' read -d '' -ra vmiIDs 0<<<"${vmiIDs[0]}"
    __ValidatePortFwds ${lPort} ${#vmiIDs[@]} ${rPort} || return 1

    (   # Silence the Job Control messages and allow `trap`.
        for e in "${vmiIDs[@]}"; do
            eval "
                virtctl port-forward ${e} ${lPort@Q}:${rPort@Q} \
                    ${vctlPortFwdOpts[@]@Q} & fwdrPIDs+=(\$!)
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



## VM Management
### Administrative Tasks
<details id="id--administrative-tasks--CreatingVM"><summary>Creating VM</summary>
<details><summary>Windows Guest OS</summary>

```shell
__SHELL=0 \
    _VIRT__NS='...ns...' \
    _VIRT__NS='ieng--vm-img' \
    _VIRT__VM__NAME='...vmName...' \
    _VIRT__VM__NAME='vm-img--windows' \
    _VIRT__VM__GUEST_OS__IMG_SRC="$(cat - 0<<'evEOF'
  CDI:
    type: AWS-S3
    credType: K8s
    credInfo:
      name: aws-s3--cred
      vaultType: BitWarden
      vaultInfo:
        name: note.AWS--IAMuser--S3vmImgWin--Chaos
        subField: cred.u-ieng--s3--vm-img--windows--ro
    url: https://s3.us-east-1.amazonaws.com/ieng--vm-image--windows--us-east-1/win11/dist/win11-25H2--template--base.qcow2
# ---
# CDI:
#   type: AWS-S3
#   credType: K8s
#   credInfo:
#     name: aws-s3--cred
#     vaultType: BitWarden
#     vaultInfo:
#       name: ...bwNoteName...
#       subField: ...bwSubFieldName...
#   url: ...s3HTTPuRL...
evEOF
)" \
    _VIRT__VM__DISK_NAME='...vmDiskName...' \
    _VIRT__VM__DISK_NAME='vhd--00-fs-rootfs' \
    _VIRT__VM__DISK_SIZE='...vmDiskSize...' \
    _VIRT__VM__DISK_SIZE='96Gi' \
    _VIRT__VM__STORAGE_CLS='...vmStorageClass...' \
    _VIRT__VM__STORAGE_CLS='gp3-csi' \
    _VIRT__VM__ARCH='amd64' \
    _VIRT__VM__SSH_KEY_PUB="${HOME}/.ssh/...sshKeyPub..." \
    _VIRT__VM__SSH_KEY_PUB="${HOME}/.ssh/openshift-qe.pub" \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        {
            typeset __shOpt="$(shopt -po xtrace)"; set +x
            [ -n "${BW_SESSION}" ] && bw sync || {
                echo 'You do NOT have an active and sync:ed BitWarden Session!!!' 1>&2
                exit 1
            }
            eval "${__shOpt}"; unset __shOpt
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset dvName="${_VIRT__VM__NAME}--vhd--00-system"

        # Create Namespace.
        oc create namespace "${_VIRT__NS}" \
            --dry-run=client -o yaml --save-config | oc apply -f -
        oc wait "Namespace/${_VIRT__NS}" \
            --for jsonpath='{.status.phase}'=Active \
            --timeout 1m 1> /dev/null

        # Prepare Credentials.
        {
            typeset credVaultType="$(yq eval '
                .CDI.credInfo.vaultType
            ' 0<<<"${_VIRT__VM__GUEST_OS__IMG_SRC}")"

            typeset __shOpt="$(shopt -po xtrace)"; set +x
            case ${credVaultType} in
              (BitWarden)
                typeset bwNoteName="$(yq eval '
                    .CDI.credInfo.vaultInfo.name
                ' 0<<<"${_VIRT__VM__GUEST_OS__IMG_SRC}")"
                typeset bwData="$(bw get item "${bwNoteName}")" || {
                    echo "You may NOT have access to BitWarden Note \`${bwNoteName}\`." 1>&2
                    exit 1
                }
              ;;
            esac
            eval "${__shOpt}"; unset __shOpt
            case $(yq eval '
                .CDI.credType
            ' 0<<<"${_VIRT__VM__GUEST_OS__IMG_SRC}") in
              (K8s)
                typeset credName="$(yq eval '
                    .CDI.credInfo.name
                ' 0<<<"${_VIRT__VM__GUEST_OS__IMG_SRC}")"; [ -n "${credName}" ]

                typeset __shOpt="$(shopt -po xtrace)"; set +x
                case ${credVaultType} in
                  (BitWarden)
                    typeset bwSubFld="$(yq eval '
                        .CDI.credInfo.vaultInfo.subField
                    ' 0<<<"${_VIRT__VM__GUEST_OS__IMG_SRC}")"; [ -n "${bwSubFld}" ]
                    eval "$(jq -r \
                        --arg fn__c "${bwSubFld}" \
                        '.fields[]? | select(.name == $fn__c).value | fromjson | (
                            "typeset accKeyId=\(.AccKeyId | @sh)",
                            "typeset accKeySecret=\(.AccKeySecret | @sh)"
                        )' \
                    0<<<"${bwData}")"
                  ;;
                esac
                eval "${__shOpt}"; unset __shOpt

                {
                    oc -n "${_VIRT__NS}" create secret generic "${credName}" \
                        --type Opaque \
                        --from-file accessKeyId=<(set +x; printf '%s' "${accKeyId}") \
                        --from-file secretKey=<(set +x; printf '%s' "${accKeySecret}") \
                        --dry-run=client -o yaml --save-config
                } | oc apply -f -
              ;;
            esac
        }

        # Create VM.
        {
            oc create -f - --dry-run=client -o json --save-config |
            jq -c \
                --arg ns "${_VIRT__NS}" \
                --arg vmName "${_VIRT__VM__NAME}" \
                --arg dvName "${dvName}" \
                --arg dvSrcType "$(yq eval '
                    .CDI.type
                ' 0<<<"${_VIRT__VM__GUEST_OS__IMG_SRC}")" \
                --arg dvSrcURL "$(yq eval '
                    .CDI.url
                ' 0<<<"${_VIRT__VM__GUEST_OS__IMG_SRC}")" \
                --arg dvSrcCred "${credName}" \
                --arg storageCls "${_VIRT__VM__STORAGE_CLS}" \
                --arg diskSize "${_VIRT__VM__DISK_SIZE}" \
                --rawfile sshKeyPub <(cat "${_VIRT__VM__SSH_KEY_PUB}") \
                '
                    .metadata|=(
                        .name=$vmName |
                        .namespace=$ns |
                        .labels."usrMeta.vmGroup"=$vmName
                    ) |
                    .spec|=(
                        .dataVolumeTemplates[]|=(
                            .metadata|=(
                                .name=$dvName |
                                .labels."usrMeta.volGroup"=$vmName
                            ) |
                            .spec|=(
                                .source=(
                                    if ($dvSrcType == "AWS-S3") then
                                        {s3: {secretRef: $dvSrcCred, url: $dvSrcURL}}
                                    else error(
                                        "Unsupported CDI source type: \($dvSrcType)"
                                    )
                                    end
                                ) |
                                .storage|=(
                                    .storageClassName=$storageCls |
                                    .resources.requests.storage=$diskSize
                                )
                            )
                        ) |
                        .template|=(
                            .metadata.labels|=(
                                ."kubevirt.io/domain"=$vmName |
                                ."kubevirt.io/vm"=$vmName
                            ) |
                            .spec.volumes[]|=(
                                if (.dataVolume != null) then
                                    .dataVolume.name=$dvName
                                elif (.name == "cloud-init-disk") then
                                    .cloudInitNoCloud.userData|=gsub(
                                        "{{ssh_public_key}}";
                                        ($sshKeyPub | @base64)
                                    )
                                else . end
                            )
                        )
                    )
                ' |
            yq -p json -o yaml eval .
        } 0<<'ocEOF' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ''
  namespace: ''
  labels:
    usrMeta.vmGroup: ''
spec:
  dataVolumeTemplates:
    - apiVersion: cdi.kubevirt.io/v1beta1
      kind: DataVolume
      metadata:
        annotations:
          cdi.kubevirt.io/storage.bind.immediate.requested: 'true'
        name: ''
        labels:
          usrMeta.volGroup: ''
      spec:
        source: {}
        storage:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: ''
          storageClassName: ''
  runStrategy: Manual
  template:
    metadata:
      labels:
        kubevirt.io/domain: ''
        kubevirt.io/vm: ''
    spec:
      architecture: amd64
      domain:
        clock:
          timer:
            hyperv:
              present: true
        cpu:
          cores: 4
          sockets: 1
          threads: 1
        devices:
          autoattachPodInterface: false
          disks:
            - bootOrder: 1
              disk:
                bus: virtio
              name: vhd--00-fs-rootfs
            - cdrom:
                bus: sata
              name: cloud-init-disk
          inputs:
            - bus: usb
              name: tablet
              type: tablet
          interfaces:
            - masquerade: {}
              model: virtio
              name: nic--0
          networkInterfaceMultiqueue: true
          tpm: {}
        features:
          hyperv:
            frequencies: {}
            ipi: {}
            reenlightenment: {}
            relaxed: {}
            reset: {}
            runtime: {}
            spinlocks:
              enabled: true
              spinlocks: 8191
            synic: {}
            synictimer:
              direct: {}
            tlbflush: {}
            vapic: {}
            vpindex: {}
          smm: {}
        firmware:
          bootloader:
            efi:
              secureBoot: true
        machine:
          type: q35
        memory:
          guest: 8Gi
        resources:
          limits:
            memory: 8Gi
          requests:
            memory: 8Gi
      networks:
        - name: nic--0
          pod: {}
      volumes:
        - dataVolume:
            name: ''
          name: vhd--00-fs-rootfs
        - cloudInitNoCloud:
            userData: |
                #cloud-config
                runcmd:
                  - powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "
                        $s = \"${env:ProgramData}\Scripts\Script--App--CloudBaseInit--Main.ps1\";
                        if (Test-Path -Path $s) {& $s}
                    "
                write_files:
                  - path: C:\ProgramData\Scripts\Data--App--CloudBaseInit--SSH.txt
                    encoding: b64
                    content: {{ssh_public_key}}
          name: cloud-init-disk
ocEOF

        # Wait for DV import to complete.
        oc -n "${_VIRT__NS}" wait "DataVolume/${dvName}" \
            --for create \
            --timeout 2m 1> /dev/null
        oc -n "${_VIRT__NS}" wait "DataVolume/${dvName}" \
            --for condition=Ready \
            --timeout 30m 1> /dev/null

        # Wait for VM to be ready to be started.
        oc -n "${_VIRT__NS}" \
            wait "VirtualMachine/${_VIRT__VM__NAME}" \
            --for jsonpath='{.status.printableStatus}'=Stopped \
            --timeout 2m 1> /dev/null

        true
cmdEOF
    )"; echo $?
```
</details>
</details>
<details><summary>Backing-Up VM</summary>

```shell
_JOB__ACTION=create \
    _VIRT__NS='...ns...' \
    _VIRT__NS='ieng--vm-img' \
    _VIRT__VM__NAME='...vmName...' \
    _VIRT__VM__NAME='vm-img--windows' \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        typeset vmbGrp="vm-backup.${_VIRT__VM__NAME}" vmbName=
        typeset vmbCRD="$(cat - 0<<'ocEOF'
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineSnapshot
metadata:
  name: ''
  namespace: ''
  labels:
    usrMeta.vmbGrp: ''
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ''
  target:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ''
ocEOF
        )"
        typeset fzfHdr= fzfOpts=

        case ${_JOB__ACTION} in
          (create)
            vmbName="${vmbGrp}.$(date -u "+%Y%m%d-%H%M%Sz")"
            read -rei "${vmbName}" -p 'Snapshot name: ' vmbName
            {
                oc create -f - --dry-run=client -o json --save-config |
                jq -c \
                    --arg vmNS "${_VIRT__NS}" \
                    --arg vmbName "${vmbName}" \
                    --arg vmbGrp "${vmbGrp}" \
                    --arg vmName "${_VIRT__VM__NAME}" \
                    '
                        .metadata|=(
                            .name=$vmbName |
                            .namespace=$vmNS |
                            .labels."usrMeta.vmbGrp"=$vmbGrp
                        ) | .spec|=(
                            .source.name=$vmName |
                            del(.target)
                        )
                    ' |
                yq -p json -o yaml eval .
            } 0<<<"${vmbCRD}" | oc apply -f -
            oc -n "${_VIRT__NS}" wait "VirtualMachineSnapshot/${vmbName}" \
                --for jsonpath='{.status.phase}'=Succeeded \
                --timeout 5m
            : "Snapshot is completed. Waiting for full BackUp to be ready..."
            oc -n "${_VIRT__NS}" wait "VirtualMachineSnapshot/${vmbName}" \
                --for condition=Ready \
                --timeout 2h
            ;;
          (list|restore|delete)
            case ${_JOB__ACTION} in
              (list)    fzfHdr='(s) to list' fzfOpts='-m --bind alt-a:toggle-all';;
              (restore) fzfHdr=' to restore';;
              (delete)  fzfHdr='(s) to delete' fzfOpts='-m --bind alt-a:toggle-all';;
            esac
            vmbName="$(
                oc -n "${_VIRT__NS}" get VirtualMachineSnapshots \
                    -l "usrMeta.vmbGrp=${vmbGrp}" \
                    --sort-by=.metadata.creationTimestamp \
                    -o json |
                jq -r '
                    .items[] |
                    "\(.metadata.name)\t[\(.metadata.creationTimestamp)]"
                ' | column -ts $'\t' |
                fzf --tac --header "Select snapshot${fzfHdr}." ${fzfOpts} |
                awk '{print $1}'
            )"
            ;;&
          (list)    echo "${vmbName}";;
          (restore)
            {
                virtctl -n "${_VIRT__NS}" stop "${_VIRT__VM__NAME}" ||
                oc -n "${_VIRT__NS}" delete "VirtualMachineInstance/${_VIRT__VM__NAME}" ||
                true
            }
            oc -n "${_VIRT__NS}" wait "VirtualMachine/${_VIRT__VM__NAME}" \
                --for jsonpath='{.status.printableStatus}'=Stopped \
                --timeout 5m 1> /dev/null
            oc -n "${_VIRT__NS}" wait "VirtualMachineInstance/${_VIRT__VM__NAME}" \
                --for delete \
                --timeout 5m 1> /dev/null || true
            oc -n "${_VIRT__NS}" delete "VirtualMachineRestore/${vmbName}" 2>/dev/null || true
            oc -n "${_VIRT__NS}" wait "VirtualMachineRestore/${vmbName}" \
                --for delete \
                --timeout 5m 1> /dev/null || true
            {
                oc create -f - --dry-run=client -o json --save-config |
                jq -c \
                    --arg crdKind VirtualMachineRestore \
                    --arg vmNS "${_VIRT__NS}" \
                    --arg vmbName "${vmbName}" \
                    --arg vmbGrp "${vmbGrp}" \
                    --arg vmName "${_VIRT__VM__NAME}" \
                    '
                        .kind=$crdKind |
                        .metadata|=(
                            .name=$vmbName |
                            .namespace=$vmNS |
                            .labels."usrMeta.vmbGrp"=$vmbGrp
                        ) | .spec|=(
                            .target.name=$vmName |
                            del(.source) |
                            .virtualMachineSnapshotName=$vmbName
                        )
                    ' |
                yq -p json -o yaml eval .
            } 0<<<"${vmbCRD}" | oc apply -f -
            oc -n "${_VIRT__NS}" wait "VirtualMachineRestore/${vmbName}" \
                --for condition=Ready \
                --timeout 30m
            oc -n "${_VIRT__NS}" delete "VirtualMachineRestore/${vmbName}"
            ;;
          (delete)
            echo "${vmbName}" |
                xargs -I{} bash -c '
                    oc -n "${_VIRT__NS}" delete "VirtualMachineSnapshot/${1}" &&
                    oc -n "${_VIRT__NS}" wait "VirtualMachineSnapshot/${1}" \
                        --for delete \
                        --timeout 5m
                ' '' '{}'
            ;;
        esac
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Destroying VM</summary>

```shell
__SHELL=0 \
    _VIRT__NS='...ns...' \
    _VIRT__NS='ieng--vm-img' \
    _VIRT__VM__NAME='...vmName...' \
    _VIRT__VM__NAME='vm-img--windows' \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        # Delete VM.
        oc -n "${_VIRT__NS}" delete vm "${_VIRT__VM__NAME}" \
            --ignore-not-found
        oc -n "${_VIRT__NS}" wait "VirtualMachine/${_VIRT__VM__NAME}" \
            --for delete \
            --timeout 5m 1> /dev/null

        # Delete Namespace if no other VMs remain.
        (($(
            oc get vm -n "${_VIRT__NS}" \
                -o jsonpath-as-json='{.items[*].metadata.name}' |
            jq 'length'
        ))) || {
            oc delete Namespace "${_VIRT__NS}" \
                --ignore-not-found
            oc wait "Namespace/${_VIRT__NS}" \
                --for delete \
                --timeout 5m 1> /dev/null
        }

        true
cmdEOF
    )"; echo $?
```
</details>


### Operational Tasks
<details id="id--operational-tasks--StartVM"><summary>Start VM</summary>

```shell
virtctl -n '...ns...' start '...vmName...'
{
    oc -n '...ns...' wait "VirtualMachineInstance/...vmName..." \
        --for create \
        --timeout 2m 1> /dev/null &&
    oc -n '...ns...' wait "VirtualMachineInstance/...vmName..." \
        --for jsonpath='{.status.phase}'=Running \
        --timeout 10m 1> /dev/null
}; echo $?
```
</details>
<details><summary>Connect to VM CLI Console</summary>

```shell
virtctl -n '...ns...' console '...vmName...'
```
</details>
<details><summary>Connect to VM GUI Console</summary>

```shell
virtctl -n '...ns...' vnc '...vmName...' --proxy-only --port ...vncPort...
```
</details>
<details><summary>SSH to VM</summary>
<details><summary>Default Shell</summary>

```shell
virtctl -n '...ns...' ssh  \
    -t '-o UserKnownHostsFile=/dev/null' \
    -t '-o StrictHostKeyChecking=no' \
    -i "${HOME}/.ssh/openshift-qe.pem" \
    'Administrator@vm/...vmName...'
```
</details>
<details><summary>PowerShell</summary>

```shell
virtctl -n '...ns...' ssh  \
    -t '-t' \
    -t '-o UserKnownHostsFile=/dev/null' \
    -t '-o StrictHostKeyChecking=no' \
    -i "${HOME}/.ssh/openshift-qe.pem" \
    'Administrator@vm/...vmName...' \
    -c 'powershell.exe'
```
</details>
</details>
<details id="operational-tasks--StopVM"><summary>Stop VM</summary>

```shell
virtctl -n '...ns...' stop '...vmName...'
oc -n '...ns...' wait "VirtualMachineInstance/...vmName..." \
    --for delete \
    --timeout 5m 1> /dev/null; echo $?
```
</details>



## Maintenance
### Creating VM Image Template
<details><summary>Creating Disk Image Template Generator VM</summary>

See [Administrative Tasks | Creating VM](#id--administrative-tasks--CreatingVM).
</details>
<details><summary>Preparing Guest OS as VM Image Template</summary>

Run on VM.
<details><summary>Windows Guest OS</summary>

It is highly recommended to customize the system via `sysprep /audit`.
<details><summary>Remote Connection: SSH Server</summary>

On Windows fresh install, remote communication is not normally available.
Either install via GUI console or local terminal:
  - **GUI** (via VNC / GUI Console):
     1. Open `Settings` → `System` → `Optional features` → `Add an optional feature`:
         1. Search for `OpenSSH Server`.
         2. Install it.
     2. Open `Services` → `OpenSSH SSH Server`:
         1. Set `Startup type`: `Automatic`.
         2. Click `Start`.
  - **CLI** (from local terminal, i.e. GUI Console PowerShell):
    ```powershell
    # Install OpenSSH Server (latest available version).
    Add-WindowsCapability -Online -Name (
        Get-WindowsCapability -Online |
        Where-Object -FilterScript {
            ($_.Name -like 'OpenSSH.Server*') -and
            ($_.State -eq 'NotPresent')
        } |
        Select-Object -ExpandProperty Name
    )

    # Start the service.
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd

    # Verify.
    Get-Service -Name 'sshd' |
        Select-Object -Property @('Name', 'Status', 'StartType')
    ```
</details>
<details><summary>SysPrep</summary>
<details><summary>Enter Audit Mode</summary>

**Notes:**
  - Do not create the Image Template at this stage. Must finalize to OOBE (Generalized) state.
  - The `Administrator` password during this mode is `win-adm`.

Run in PowerShell as `Administrator`:
```powershell
& {
    # Hard-coded password for seamless Audit Mode auto-logon.
    $admPwd = 'win-adm'

    # Create Audit `unattend` file.
    Set-Content `
        -Path "${env:SystemRoot}\System32\Sysprep\unattend--audit.xml" `
        -Encoding UTF8 -NoNewline `
        -Value (@'
<?xml version="1.0" encoding="utf-8"?>
<unattend
    xmlns="urn:schemas-microsoft-com:unattend"
    xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
>
  <settings pass="auditSystem">
    <component
      name="Microsoft-Windows-Shell-Setup"
      processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35"
      language="neutral"
      versionScope="nonSxS"
    >
      <AutoLogon>
        <Username>Administrator</Username>
        <Password>
'@ + "`n" + @"
          <Value>$(
            [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("${admPwd}Password"))
          )</Value>
"@ + "`n" + @'
          <PlainText>false</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>9</LogonCount>
      </AutoLogon>
      <UserAccounts>
        <AdministratorPassword>
'@ + "`n" + @"
          <Value>$(
            [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("${admPwd}AdministratorPassword"))
          )</Value>
"@ + "`n" + @'
          <PlainText>false</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
  <settings pass="auditUser">
    <component
      name="Microsoft-Windows-Deployment"
      processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35"
      language="neutral"
      versionScope="nonSxS"
    >
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>10</Order>
          <Path>powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "@('UsoSvc', 'wuauserv') | ForEach-Object -Process {Set-Service -Name $_.Name -StartupType Manual; Stop-Service -Name $_.Name -Force}"</Path>
          <WillReboot>Never</WillReboot>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
'@ + "`n")
}

# Clean Auto-Logon.
Remove-ItemProperty `
    -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
    -Name @(
        'AutoAdminLogon', 'AutoLogonSID',
        'DefaultDomainName', 'DefaultUserName', 'DefaultPassword',
        'LastUsedUsername'
    ) `
    -ErrorAction SilentlyContinue

# Enter Audit Mode.
($(
    $okTag = "${env:SystemRoot}\System32\Sysprep\Sysprep_succeeded.tag"
    Remove-Item -Path $okTag -Force -ErrorAction SilentlyContinue
    ((
        Start-Process `
            -Wait -NoNewWindow -PassThru `
            -FilePath "${env:SystemRoot}\System32\Sysprep\sysprep.exe" `
            -ArgumentList @(
                '/quiet', '/audit', '/reboot', (
                    "`"/unattend:" +
                    "${env:SystemRoot}\System32\Sysprep\" +
                    "unattend--audit.xml`""
                )
            )
    ).ExitCode -eq 0) -and (Test-Path -Path $okTag)
) -or (
    Write-Host 'SysPrep FAIL!!!' `
        -BackgroundColor Black -ForegroundColor Red
)) | Out-Null
```
</details>
<details><summary>Customize</summary>
<details><summary>Common</summary>

  - <details><summary>PowerShell Profile</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    # Create system-wide PowerShell Profile.
    Set-Content `
        -Path "$($PROFILE.AllUsersAllHosts)" `
        -Encoding UTF8 -NoNewline `
        -Value (@'
    function prompt {
        "`n${env:USERNAME}@${env:COMPUTERNAME}.$((Get-History -Count 1).Id + 1) " +
            "$(Get-Date -UFormat '%Y-%m-%d w%V %T') " +
            "$(if ((Get-Location -Stack).Count) {'['+(Get-Location -Stack).Count.ToString()+']'})" +
            """$($executionContext.SessionState.Path.CurrentLocation)""`n" +
            "$($(if (([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {'#'} else {'$'}) * ($nestedPromptLevel + 1)) "
    }

    function sudo {
        Start-Process -FilePath "$((Get-Process -Id ${PID}).Path)" -WorkingDirectory "$($executionContext.SessionState.Path.CurrentLocation)" -Verb RunAs -Wait
    }

    function dirs {
        switch -Wildcard ($PSVersionTable.PSVersion.ToString()) {
            '[1234].*' {
                (Get-Location -Stack) | ForEach-Object -Process {$_.Path}
                break
            }
            '*' {
                (Get-Location -Stack).Path
                break
            }
        }
    }

    function WinCRTcmdLnEnc {
        param(
            [Parameter(Mandatory)]
            [string] $Value
        )

        $sb = [System.Text.StringBuilder]::new()

        [void]$sb.Append('"')
        $backslashes = 0
        foreach ($c in $Value.ToCharArray()) {
            if ($c -eq '\') {
                $backslashes++
                continue
            }

            if ($c -eq '"') {
                # Double all preceding BackSlashes,
                # then escape the Double-Quote itself.
                [void]$sb.Append(('\' * (($backslashes * 2) + 1)))
                [void]$sb.Append('"')
                $backslashes = 0
                continue
            }

            # Ordinary character: emit accumulated BackSlashes unchanged.
            if ($backslashes) {
                [void]$sb.Append(('\' * $backslashes))
                $backslashes = 0
            }

            [void]$sb.Append($c)
        }

        # BackSlashes immediately before the closing quote must be doubled.
        if ($backslashes) {
            [void]$sb.Append(('\' * ($backslashes * 2)))
        }
        [void]$sb.Append('"')

        $sb.ToString()
    }

    # Skip saving to Command History File if starts with `Space`,
    Set-PSReadLineOption -AddToHistoryHandler {
        param([string]$Line)
        -not $Line.StartsWith(' ')
    }
    # History functionality shortcut.
    if (Test-Path -Path Alias:h) {Remove-Item -Path Alias:h -Force}
    function h {
        [CmdletBinding()]
        param(
            [Alias('c')]
            [switch]$Clear
        )

        if ($Clear) {Clear-History} else {Get-History}
    }

    # Source custom settings.
    Get-ChildItem `
        -Path (
            Join-Path `
                -Path (Split-Path -Path $PROFILE.AllUsersAllHosts -Parent) `
                -ChildPath 'profile--app--*.ps1'
            ) `
        -ErrorAction SilentlyContinue |
        ForEach-Object -Process {. $_.FullName}
    '@ + "`n")

    # Allow sourcing the profile.
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    ```
    </details>
  - <details><summary>SSH</summary>
    <details><summary>Setting Up</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    & {
        # Generate SSH key pair for `Administrator`.
        $admSSHdir = "${env:USERPROFILE}\.ssh"
        New-Item -ItemType Directory -Path $admSSHdir -Force 1> $null
        @('ed25519') | ForEach-Object -Process {
            if (-not (Test-Path -Path "${admSSHdir}\id_${_}")) {
                ssh-keygen -q -t $_ -f "${admSSHdir}\id_${_}" -N '""'
            }
        }

        # Allow `Administrator` to SSH to localhost as other users.
        $usrProfRoot     =  Split-Path -Path ${env:USERPROFILE} -Parent
        $pubKeys         =  @(
                                Get-ChildItem `
                                    -Path $admSSHdir `
                                    -Filter '*.pub' `
                                    -File |
                                ForEach-Object -Process {
                                    Get-Content -Path $_.FullName
                                }
                            )
        $pubKeyBodies    =  @(
                                $pubKeys |
                                ForEach-Object -Process {($_ -split ' ')[1]}
                            )

        @('qa-usr') | ForEach-Object -Process {
            $usrID = $_
            if (
                Get-LocalGroupMember -Group 'Administrators' |
                Where-Object -FilterScript {$_.Name -like "*\${usrID}"}
            ) {
                $authFile    =  "${env:ProgramData}\ssh\administrators_authorized_keys"
                $usrACL      =  ''
            } else {
                $sshDir = "${usrProfRoot}\${usrID}\.ssh"
                New-Item -ItemType Directory -Path $sshDir -Force 1> $null
                $acl = Get-Acl -Path $sshDir
                $acl.SetOwner([System.Security.Principal.NTAccount]$usrID)
                Set-Acl -Path $sshDir -AclObject $acl
                $authFile    =  "${sshDir}\authorized_keys"
                $usrACL      =  "${usrID}:(M)"
            }
            $lines = @($(if (Test-Path -Path $authFile) {
                Get-Content -Path $authFile |
                Where-Object -FilterScript {($_ -split ' ')[1] -notin $pubKeyBodies}
            } else {@()}))
            ($pubKeys + $lines) | Set-Content $authFile -Encoding Ascii
            if ($usrACL) {
                $acl = Get-Acl -Path $authFile
                $acl.SetOwner([System.Security.Principal.NTAccount]$usrID)
                Set-Acl -Path $authFile -AclObject $acl
            }
            . {
                icacls.exe $authFile /reset
                icacls.exe $authFile `
                    /inheritance:r `
                    /grant:r `
                        $usrACL `
                        'BUILTIN\Administrators:(F)' `
                        'NT AUTHORITY\SYSTEM:(F)'
            } 1> $null
        }

        # Aliases.
        Set-Content `
            -Path "$(
                Join-Path `
                    -Path (Split-Path -Path $PROFILE.AllUsersAllHosts -Parent) `
                    -ChildPath 'profile--app--ssh.ps1'
            )" `
            -Encoding UTF8 -NoNewline `
            -Value (@'
    function ssh {
        & ssh.exe `
            -o UserKnownHostsFile=/dev/null `
            -o StrictHostKeyChecking=no `
            @args
    }
    function scp {
        & scp.exe `
            -o UserKnownHostsFile=/dev/null `
            -o StrictHostKeyChecking=no `
            @args
    }
    '@ + "`n")
    }
    ```
    </details>
    <details><summary>Administrator Passwordless Login to Other User</summary>

    To switch to other user from an active `Administrator` SSH session:
    ```powershell
    # Default Shell.
    ssh '...usr...@localhost'

    # PowerShell.
    ssh -t `
        '...usr...@localhost' `
        @(
            'powershell.exe', '-NoExit', '-Command',
            '"$env:PSREADLINE_VTINPUT = 1; Import-Module -Name ''PSReadLine'' -Force"'
        )
    ```
    </details>
  - <details><summary>Package Manager</summary>

    Run in PowerShell as `Administrator` (re-register):
    ```powershell
    & {
        @('NuGet') | ForEach-Object -Process {
            Install-PackageProvider -Name $_ -Scope AllUsers -Force -MinimumVersion (
                [System.Version]'2.8.5.201'
            )
            . {
                Get-PackageProvider -Name $_ -ListAvailable |
                Sort-Object Version |
                Select-Object -SkipLast 1 |
                ForEach-Object -Process {
                    Remove-Item (
                        Split-Path -Path $_.ProviderPath -Parent
                    ) -Recurse -Force
                }
            }
        }
    }
    ```
    </details>
  ---
  - <details><summary>WinGet</summary>
    <details><summary>Install / Repair</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    # Install / update Microsoft PowerShell Module WinGet (to manage WinGet).
    @('Microsoft.WinGet.Client') | ForEach-Object -Process {
        Install-Module -Name $_ -Scope AllUsers -Force -SkipPublisherCheck
        . {
            Get-InstalledModule -Name $_ -AllVersions |
            Sort-Object Version |
            Select-Object -SkipLast 1 |
            ForEach-Object -Process {
                Uninstall-Module -Name $_.Name -RequiredVersion $_.Version -Force
            }
        }
    }

    # Install / repair WinGet for All Users.
    Repair-WinGetPackageManager -AllUsers -Latest -Force

    # Update local source cache.
    winget source reset --force --disable-interactivity
    winget source update --disable-interactivity
    ```
    </details>
    <details><summary>Redo Registration</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    & {
        $cpuArch = switch ($env:PROCESSOR_ARCHITECTURE) {
            'AMD64' {'x64'}
            'ARM64' {'arm64'}
            'x86'   {'x86'}
            default {
                throw "Unsupported CPU Architecture: ${env:PROCESSOR_ARCHITECTURE}"
            }
        }

        $provPkg = (
            Get-AppxProvisionedPackage -Online |
            Where-Object -FilterScript {
                $_.DisplayName -eq 'Microsoft.DesktopAppInstaller'
            } |
            Sort-Object Version -Descending |
            Select-Object -First 1
        )

        $pkgMnfst = [Environment]::ExpandEnvironmentVariables($provPkg.InstallLocation)
        [xml]$xml  = Get-Content -Path $pkgMnfst -Raw
        switch ($xml.DocumentElement.LocalName) {
            'Package' {
                $appVer      =  $xml.Package.Identity.Version
                $appMnfst    =  $pkgMnfst
            }
            'Bundle' {
                $appPkgs = @(
                    $xml.SelectNodes("//*[local-name()='Package']") |
                    Where-Object -FilterScript {
                        ($_.Type -eq 'application') -and
                        ($_.Architecture -eq $cpuArch) -and
                        ($_.IsStub -ne 'true')
                    }
                )
                if ($appPkgs.Count -eq 0) {
                    throw `
                        "No ${cpuArch} Application Package in $(
                            $provPkg.DisplayName
                        )."
                } elseif ($appPkgs.Count -gt 1) {
                    throw `
                        "Multiple ${cpuArch} Application Packages in $(
                            $provPkg.DisplayName
                        )."
                } else {$appPkg = $appPkgs[0]}

                $installed = @(
                    Get-AppxPackage -AllUsers |
                    Where-Object -FilterScript {
                        ($_.Name -eq $provPkg.DisplayName) -and
                        ($_.Version -eq [version]$appPkg.Version) -and
                        ($_.Architecture -eq $cpuArch)
                    }
                )[0]
                if (-not $installed) {
                    throw `
                        "Installed package not found: $(
                            $provPkg.DisplayName
                        ) $($appPkg.Version) ${cpuArch}."
                }

                $appVer      =  $appPkg.Version
                $appMnfst    =  (
                    Join-Path `
                        -Path $installed.InstallLocation `
                        -ChildPath 'AppxManifest.xml'
                )
            }
            default {
                throw `
                    "Unknown AppX XML root ``$(
                        $xml.DocumentElement.LocalName
                    )`` for $($provPkg.DisplayName)."
            }
        }

        Write-Host "Registering $($provPkg.DisplayName) ${appVer}..."
        Add-AppxPackage -Register $appMnfst -DisableDevelopmentMode
    }
    ```
    </details>
  - <details><summary>CoreUtils</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    winget install `
        --id 'Microsoft.Coreutils' `
        --scope machine `
        --accept-package-agreements `
        --accept-source-agreements

    #   PowerShell Profile.
    & {
        Set-Content `
            -Path "$(
                Join-Path `
                    -Path (Split-Path -Path $PROFILE.AllUsersAllHosts -Parent) `
                    -ChildPath 'profile--app--core-utils.ps1'
            )" `
            -Encoding UTF8 -NoNewline `
            -Value (@'
    . {
        @(
            'ls', 'cp', 'mv', 'rm', 'mkdir', 'rmdir', 'cat'
        ) | ForEach-Object -Process {
            Remove-Item Alias:$_ -ErrorAction SilentlyContinue
        }
    '@ + "`n" + "$(
        Get-ChildItem `
            -Path "${env:ProgramFiles}\coreutils" `
            -Recurse `
            -Filter 'find.exe' `
            -ErrorAction SilentlyContinue |
        Sort-Object FullName |
        Select-Object -Last 1 -ExpandProperty FullName |
        ForEach-Object -Process {
            $binPath = "'$(
                [System.Management.Automation.Language.CodeGeneration]::`
                EscapeSingleQuotedStringContent($_)
            )'"
            "    function find {& ${binPath} `$args}"
        }
    )" + "`n" + @'
        function ls {ls.exe -F --color=auto @args}
        function ll {ls.exe -laF @args | less -F}
    }
    '@ + "`n")
    }
    ```
    </details>
  - <details><summary>Text Editor/Viewer</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    #   VIM.
    winget install `
        --id 'vim.vim' `
        --scope machine `
        --accept-package-agreements `
        --accept-source-agreements
    ##  System-wide Settings.
    Add-Content `
        -Path "${env:ProgramFiles}\Vim\_vimrc" `
        -Encoding Ascii -NoNewline `
        -Value (@'

    set nobackup
    set nowritebackup
    set noswapfile
    set noundofile
    '@ + "`n")

    #   Less.
    winget install `
        --id 'jftuga.less' `
        --scope machine `
        --accept-package-agreements `
        --accept-source-agreements
    ##  System-wide Settings.
    [Environment]::SetEnvironmentVariable('LESSHISTFILE', '-', 'Machine')
    $env:LESSHISTFILE = "-"

    #   PowerShell Profile.
    & {
        Set-Content `
            -Path "$(
                Join-Path `
                    -Path (Split-Path -Path $PROFILE.AllUsersAllHosts -Parent) `
                    -ChildPath 'profile--app--text.ps1'
            )" `
            -Encoding UTF8 -NoNewline `
            -Value (@'
    . {
    '@ + "`n" + "$(
        Get-ChildItem `
            -Path "${env:ProgramFiles}\Vim" `
            -Recurse `
            -Filter 'vim.exe' `
            -ErrorAction SilentlyContinue |
        Sort-Object FullName |
        Select-Object -Last 1 -ExpandProperty FullName |
        ForEach-Object -Process {
            $binPath = "'$(
                [System.Management.Automation.Language.CodeGeneration]::`
                EscapeSingleQuotedStringContent($_)
            )'"
            (
            "    Set-Alias -Name vim -Value ${binPath} -Scope Global`n" +
            "    Set-Alias -Name vi  -Value ${binPath} -Scope Global`n"
            )
        }
    )" + "`n" + @'
    }
    '@ + "`n")
    }
    ```
    </details>
  - <details><summary>Extra Utilities</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    #   Fuzzy Find (`fzf`).
    winget install `
        --id 'junegunn.fzf' `
        --scope machine `
        --accept-package-agreements `
        --accept-source-agreements
    ##  PowerShell History with `fzf`.
    Install-Module -Name PSFzf -Scope AllUsers -Force -SkipPublisherCheck


    #   Advanced Find (`fd`).
    winget install `
        --id 'sharkdp.fd' `
        --scope machine `
        --accept-package-agreements `
        --accept-source-agreements

    #   RipGrep.
    winget install `
        --id 'BurntSushi.ripgrep.MSVC' `
        --scope machine `
        --accept-package-agreements `
        --accept-source-agreements

    #   PowerShell Profile.
    Set-Content `
        -Path "$(
            Join-Path `
                -Path (Split-Path -Path $PROFILE.AllUsersAllHosts -Parent) `
                -ChildPath 'profile--app--extra-Utils.ps1'
        )" `
        -Encoding UTF8 -NoNewline `
        -Value (@'
    . {
        # Lazy-load `PSFzf` module on demand.
        function InitPSFzf {
            Import-Module -Name 'PSFzf'
            Set-PsFzfOption `
                -PSReadlineChordReverseHistory      'Ctrl+f,c' `
                -PSReadlineChordReverseHistoryArgs  'Ctrl+f,a' `
                -PSReadlineChordProvider            'Ctrl+f,p' `
                -PSReadlineChordSetLocation         'Ctrl+f,d'
            Remove-Item "Function:\$($MyInvocation.MyCommand.Name)"
        }
        Set-PSReadLineKeyHandler -Chord 'Ctrl+f,c' -ScriptBlock {
            if (Test-Path Function:\InitPSFzf) {InitPSFzf}
            Invoke-FzfPsReadlineHandlerHistory
        }
        Set-PSReadLineKeyHandler -Chord 'Ctrl+f,a' -ScriptBlock {
            if (Test-Path Function:\InitPSFzf) {InitPSFzf}
            Invoke-FzfPsReadlineHandlerHistoryArgs
        }
        Set-PSReadLineKeyHandler -Chord 'Ctrl+f,p' -ScriptBlock {
            if (Test-Path Function:\InitPSFzf) {InitPSFzf}
            Invoke-FzfPsReadlineHandlerProvider
        }
        Set-PSReadLineKeyHandler -Chord 'Ctrl+f,d' -ScriptBlock {
            if (Test-Path Function:\InitPSFzf) {InitPSFzf}
            Invoke-FzfPsReadlineHandlerSetLocation
        }
    }
    '@ + "`n")
    ```
    </details>
  - <details><summary>Sysinternals</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    & {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'

        $binDir  =  "${env:SystemDrive}\BIN"
        $tmpDir  =  "${env:TEMP}\SysinternalsBin"
        $zipPath =  "${env:TEMP}\SysinternalsSuite.zip"

        New-Item -ItemType Directory -Path $tmpDir -Force 1> $null
        Invoke-WebRequest `
            -Uri 'https://download.sysinternals.com/files/SysinternalsSuite.zip' `
            -OutFile $zipPath
        Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
        Remove-Item -Path $zipPath -Force

        # Use 64-bit version only.
        Push-Location -Path $tmpDir
        Get-ChildItem -Path .\ -Filter '*64.exe' | ForEach-Object -Process {
            $baseName = $_.BaseName -replace '64$', ''
            if (Test-Path -Path ".\${baseName}.exe") {
                Remove-Item -Path ".\${baseName}.exe" -Force
                # In PS 5.1, the `New-Item -ItemType SymbolicLink ...` always
                #   resolve the `-Target` to Absolute Path.
                $env:ComSpec /C "`"MKLINK `"${baseName}.exe`" `".\$($_.Name)`"`""
            }
        }
        Pop-Location

        # Move all files to BIN.
        New-Item -ItemType Directory -Path $binDir -Force 1> $null
        Move-Item -Path "${tmpDir}\*" -Destination $binDir -Force
        Remove-Item -Path $tmpDir -Force

        ##  System-wide Settings.
        [Environment]::SetEnvironmentVariable('Path', "$(
            "${binDir};" + ((
                [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' |
                Where-Object -FilterScript {$_ -and $_ -ne $binDir}
            ) -join ';')
        )", 'Machine')

        # Pre-accept EULA for all tools (current user + new-user template).
        Get-ChildItem -Path $binDir -Filter '*.exe' | ForEach-Object -Process {
            $tool = [IO.Path]::GetFileNameWithoutExtension($_.Name)
            @(
                'HKCU:\Software\Sysinternals',
                'Registry::HKEY_USERS\.DEFAULT\Software\Sysinternals'
            ) | ForEach-Object -Process {
                $regPath = "${_}\${tool}"
                New-Item -Path $regPath -Force 1> $null
                Set-ItemProperty `
                    -Path $regPath `
                    -Name 'EulaAccepted' `
                    -Type DWord -Value 1
            }
        }
    }
    ```
    </details>
  ---
  - <details><summary>QA Directory Structures</summary>

    **Notes:**
      - Directory structure:
        ```
        %SystemDrive%
         |- QA
         |   |- Script
         |   |   |- QA--Test.ps1
         |   |- StartUp
         |   |   |- QA--StartUp.cmd
         |   |- Temp
         |   |- Test
         |       |- QA--Test--<NNN...>--<testDesc>.ps1  # Executed by `QA--Test.ps1`.
         |       |- QA--Test--x<NNN...>--<testDesc>.ps1 # Skipped (rename: add `x` prefix to number).
         |- TEMP                                        # Junction to `\QA\Temp`.
         |- TMP                                         # Junction to `\QA\Temp`.
        ```

    Run in PowerShell as `Administrator`:
    ```powershell
    & {
        # Root Directory.
        . {
            # Allow rename/delete protection of direct children via `Deny DE`
            #   ACL Permission.
            icacls.exe "${env:SystemDrive}\" `
                /deny 'NT AUTHORITY\Authenticated Users:(DC)' `
                1> $null
        }

        # Directories.
        @('Script', 'StartUp', 'Temp', 'Test') | ForEach-Object -Process {New-Item `
            -ItemType Directory `
            -Path "${env:SystemDrive}\QA\${_}" `
            -Force `
        1> $null}
        @('TEMP', 'TMP') | ForEach-Object -Process {
            $path = "${env:SystemDrive}\${_}"
            if (-not (Test-Path -Path $path)) {New-Item `
                -ItemType Junction `
                -Path $path `
                -Target "${env:SystemDrive}\QA\Temp" `
                -Force `
            1> $null}
            icacls.exe $path `
                /deny 'NT AUTHORITY\Authenticated Users:(DE)' `
                1> $null
        }

        # Set Permissions.
        & {
            $path = "${env:SystemDrive}\QA"
            . {
                icacls.exe "${path}" /reset
                # Full Control for `SYSTEM` and `Administrator`.
                # R/O: This folder and direct children for `Authenticated Users`.
                icacls.exe "${path}" `
                    /inheritance:r `
                    /grant:r `
                        'NT AUTHORITY\Authenticated Users:(OI)(CI)(NP)(RX)' `
                        'Administrator:(OI)(CI)(F)' `
                        'NT AUTHORITY\SYSTEM:(OI)(CI)(F)' `
                    /deny `
                        'NT AUTHORITY\Authenticated Users:(DE)'
            } 1> $null  # Restrict access.

            @('Script', 'StartUp') | ForEach-Object -Process {
                $chldPath = "${path}\${_}"
                . {
                    icacls.exe "${chldPath}" /reset
                    # R/O for `Authenticated Users`.
                    icacls.exe "${chldPath}" `
                        /grant:r `
                            'NT AUTHORITY\Authenticated Users:(OI)(CI)(IO)(RX)'
                } 1> $null
            }   # R/O access.

            @('Temp', 'Test') | ForEach-Object -Process {
                $chldPath = "${path}\${_}"
                . {
                    icacls.exe "${chldPath}" /reset
                    icacls.exe "${chldPath}" `
                        /grant:r `
                            'NT AUTHORITY\Authenticated Users:(OI)(CI)(IO)(F)' `
                            'NT AUTHORITY\Authenticated Users:(W)'
                } 1> $null
            }   # Full Control for the lower structures.
        }
    }

    # File `QA--StartUp.cmd`.
    Set-Content `
        -Path "${env:SystemDrive}\QA\StartUp\QA--StartUp.cmd" `
        -Encoding Ascii -NoNewline `
        -Value (@'
    @ECHO OFF
    SET _launcher=%SystemDrive%\QA\Script\QA--Test.ps1
    IF EXIST "%_launcher%" powershell.exe -ExecutionPolicy Bypass -File "%_launcher%" && EXIT /B 0 || EXIT /B 1
    '@ + "`n")

    # File `QA--Test.ps1`.
    Set-Content `
        -Path "${env:SystemDrive}\QA\Script\QA--Test.ps1" `
        -Encoding UTF8 -NoNewline `
        -Value (@'
    . {
        Get-ChildItem -Path "${env:SystemDrive}\QA\Test" -Filter 'QA--Test--*.ps1' |
        Where-Object -FilterScript {$_.Name -match '^QA--Test--\d+--.*\.ps1$'} |
        Sort-Object -Property Name |
        ForEach-Object -Process {& $_.FullName}
    }
    '@ + "`n")
    ```
    </details>
  - <details><summary>Bootstrap <code>QA User</code> login</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    # Login as `qa-usr`.
    ssh -t `
        'qa-usr@localhost' `
        @(
            'powershell.exe', '-NoExit', '-Command',
            '"$env:PSREADLINE_VTINPUT = 1; Import-Module -Name ''PSReadLine'' -Force"'
        )
    ```
    Run in PowerShell as `qa-usr`:
    ```powershell
    # Start test at login.
    New-Item `
        -ItemType SymbolicLink `
        -Path "${env:APPDATA}\Microsoft\Windows\Start Menu\Programs\Startup\QA--StartUp.cmd" `
        -Target "${env:SystemDrive}\QA\StartUp\QA--StartUp.cmd" `
        -Force
    ```
    </details>
</details>
<details><summary>Targeted</summary>
</details>
</details>
<details><summary>OS Update</summary>
<details><summary>Windows Update</summary>

Run in PowerShell as `Administrator`:
```powershell
& {
    $ErrorActionPreference = 'Stop'

    $execScript = @'
. {
    $ErrorActionPreference = 'Stop'

    function GetWUAresCodeName {
        param(
            [Parameter(Mandatory)]
            [int] $Code
        )

        switch ($Code) {
            0       {'NotStarted'}
            1       {'InProgress'}
            2       {'Succeeded'}
            3       {'SucceededWithErrors'}
            4       {'Failed'}
            5       {'Aborted'}
            default {"Unknown($Code)"}
        }
    }

    $wuaSes = New-Object -ComObject Microsoft.Update.Session
    $wuaSes.ClientApplicationID = 'Windows Update Script'

    # Scan for updates.
    Write-Host "`nSearching for applicable updates..."
    $wuaScanner = $wuaSes.CreateUpdateSearcher()
    $scanRes = $wuaScanner.Search(
        "IsInstalled=0 and IsHidden=0 and Type='Software'"
    )
    Write-Host "Search result: $(GetWUAresCodeName $scanRes.ResultCode)"
    Write-Host "Updates found: $($scanRes.Updates.Count)"
    if ($scanRes.Updates.Count -eq 0) {
        Write-Host 'No applicable updates.'
        return
    }

    $winUpds = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($i = 0; $i -lt $scanRes.Updates.Count; $i++) {
        $upd = $scanRes.Updates.Item($i)
        Write-Host "  Available [$($i + 1)/$($scanRes.Updates.Count)]:"
        Write-Host "    $($upd.Title)"
        Write-Host "    KB: $($upd.KBArticleIDs -join ', ')"
        Write-Host "    Downloaded: $($upd.IsDownloaded)"
        if (-not $upd.EulaAccepted) {$upd.AcceptEula()}
        [void]$winUpds.Add($upd)
    }

    # Download updates.
    Write-Host "`nDownloading $($winUpds.Count) updates..."
    $wuaDL = $wuaSes.CreateUpdateDownloader()
    $wuaDL.Updates = $winUpds
    $dlRes = $wuaDL.Download()
    Write-Host "Download result: $(GetWUAresCodeName $dlRes.ResultCode)"

    for ($i = 0; $i -lt $winUpds.Count; $i++) {
        $upd = $winUpds.Item($i)
        $res = $dlRes.GetUpdateResult($i)
        Write-Host "  Download [$($i + 1)/$($winUpds.Count)]:"
        Write-Host "    $($upd.Title)"
        Write-Host "    Result: $(GetWUAresCodeName $res.ResultCode)"
        Write-Host "    HResult: 0x$('{0:X8}' -f ($res.HResult -band 0xffffffff))"
    }

    $dlErrCnt = 0
    for ($i = 0; $i -lt $winUpds.Count; $i++) {
        if ($dlRes.GetUpdateResult($i).ResultCode -notin @(2, 3)) {$dlErrCnt++}
    }
    if ($dlErrCnt) {
        throw "There were ${dlErrCnt} updates that failed to download."
    }

    # Install updates.
    Write-Host "`nInstalling $($winUpds.Count) updates..."
    $wuaInst = $wuaSes.CreateUpdateInstaller()
    $wuaInst.Updates = $winUpds
    $instRes = $wuaInst.Install()
    Write-Host "Install result: $(GetWUAresCodeName $instRes.ResultCode)"
    Write-Host "Reboot required: $($instRes.RebootRequired)"

    for ($i = 0; $i -lt $winUpds.Count; $i++) {
        $upd = $winUpds.Item($i)
        $res  = $instRes.GetUpdateResult($i)
        Write-Host "  Install [$($i + 1)/$($winUpds.Count)]:"
        Write-Host "    $($upd.Title)"
        Write-Host "    Result: $(GetWUAresCodeName $res.ResultCode)"
        Write-Host "    HResult: 0x$('{0:X8}' -f ($res.HResult -band 0xffffffff))"
    }

    $instErrCnt = 0
    for ($i = 0; $i -lt $winUpds.Count; $i++) {
        if ($instRes.GetUpdateResult($i).ResultCode -notin @(2, 3)) {$instErrCnt++}
    }

    if ($instErrCnt) {
        throw "There were ${instErrCnt} updates that failed to install."
    } else {
        Write-Host "`nWindows Update installation completed successfully."
    }

    if ($instRes.RebootRequired) {
        Write-Host 'A reboot is required.'
    }
} *> "${env:SystemRoot}\Temp\wua.log"
'@

    # Schedule a Task as `SYSTEM`.
    $wuTask = 'WinUpd'
    $wuLog = "${env:SystemRoot}\Temp\wua.log"
    Unregister-ScheduledTask `
        -Confirm:$false `
        -TaskName $wuTask `
        -ErrorAction SilentlyContinue
    Remove-Item -Path $wuLog -Force -ErrorAction SilentlyContinue
    Register-ScheduledTask `
        -TaskName $wuTask `
        -Action (
            New-ScheduledTaskAction `
                -Execute 'powershell.exe' `
                -Argument (
                    '-NoProfile ' +
                    '-NonInteractive ' +
                    '-WindowStyle Hidden ' +
                    "-EncodedCommand $([Convert]::ToBase64String(
                        [Text.Encoding]::Unicode.GetBytes($execScript)
                    ))"
                )
        ) `
        -Principal (
            New-ScheduledTaskPrincipal `
                -UserId 'SYSTEM' `
                -LogonType ServiceAccount `
                -RunLevel Highest
        ) `
        -Force 1> $null

    # Start the Task.
    #   Use Task Scheduler COM API to run the Task without being queued during
    #   Audit Mode (mimic `SCHTASKS /Run /I ...`).
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    $task = $svc.GetFolder('\').GetTask($wuTask)
    $task.RunEx(
        $null,  # params
        0x2,    # flags = (TASK_RUN_IGNORE_CONSTRAINTS)
        0,      # sessionID
        ''      # user
    )
    while ((
        Get-ScheduledTaskInfo -TaskName $wuTask
    ).LastTaskResult -in @(0x41303, 0x41301)) {
        Start-Sleep -Seconds 5
    }
    $wuRes = (Get-ScheduledTaskInfo -TaskName $wuTask).LastTaskResult

    # Remove the Task.
    Unregister-ScheduledTask `
        -Confirm:$false `
        -TaskName $wuTask `
        -ErrorAction SilentlyContinue
    Get-Content -Path $wuLog -ErrorAction SilentlyContinue
    Remove-Item -Path $wuLog -Force -ErrorAction SilentlyContinue
    if ($wuRes) {
        throw "Windows Update task failed with exit code: 0x$(
            '{0:X8}' -f $wuRes
        )"
    }

    # Reboot if required.
    $wuRegRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion'
    if (
        (Test-Path -Path "${wuRegRoot}\WindowsUpdate\Auto Update\RebootRequired") -or
        (Test-Path -Path "${wuRegRoot}\Component Based Servicing\RebootPending")
    ) {Restart-Computer -Force}
}
```
</details>
<details><summary>Feature Update</summary>

**Pre-requisites:**
  - Windows Installation ISO available at a publicly fetchable URL (e.g. S3 public bucket).

Run in PowerShell as `Administrator`:
```powershell
& {
    $isoPath = "${env:SystemDrive}\WinInstall.iso"

    # Download ISO.
    & {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest `
            -Uri '...isoS3Url...' `
            -OutFile $isoPath
    }

    # Mount ISO and run in-place upgrade.
    $isoDrv = (
        Mount-DiskImage -ImagePath $isoPath -PassThru |
        Get-Volume
    ).DriveLetter
    Start-Process `
        -Wait -NoNewWindow `
        -FilePath "${isoDrv}:\setup.exe" `
        -ArgumentList @(
            '/auto upgrade', '/quiet', '/eula accept', '/compat ignorewarning',
            '/DynamicUpdate disable', '/Telemetry Disable', '/ShowOOBE none'
        )
}
```
**Notes:**
  - Verify after reboot.
    ```powershell
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
        Select-Object -Property @('DisplayVersion', 'CurrentBuild')
    ```
  - Wait for post-upgrade `setup` process to fully exit before proceeding (it may take a very long time).
    ```powershell
    . {
        while (Get-Process setup -ErrorAction SilentlyContinue) {
            Write-Host "Waiting for setup to complete..."
            Start-Sleep -Seconds 30
        }
        Write-Host "Setup completed at: $(
            Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
        )"
    }
    ```
</details>
<details><summary>System CleanUp</summary>

Run in PowerShell as `Administrator`:
```powershell
# Remove previous OS BackUp and Installation ISO.
Remove-Item -Path @(
    "${env:SystemDrive}\Windows.old",
    "${env:SystemDrive}\WinInstall.iso"
) -Recurse -Force -ErrorAction SilentlyContinue

# Set `Update Session Orchestrator` Service to Manual.
Set-Service -Name UsoSvc -StartupType Manual
Stop-Service -Name UsoSvc -Force -ErrorAction SilentlyContinue

# Clear Windows Update download cache.
Stop-Service -Name wuauserv -Force
Remove-Item `
    -Path "${env:SystemRoot}\SoftwareDistribution\Download\*" `
    -Recurse -Force -ErrorAction SilentlyContinue

# Clear Shadow Copies.
vssadmin.exe Delete Shadows /For=$env:SystemDrive /all

# DISM Component Store cleanup.
DISM.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase

# Complete Disk cleanup.
& {
    $ErrorActionPreference = 'Stop'

    $handlers    =  Get-ChildItem -Path (
                        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion' +
                        '\Explorer\VolumeCaches'
                    )
    $flag        = 'StateFlags9999'
    $tskName     = 'DiskCleanup9999'

    try {
        $handlers | ForEach-Object -Process {
            New-ItemProperty `
                -Path $_.PSPath `
                -Name $flag `
                -PropertyType DWord `
                -Value 2 `
                -Force 1> $null
        }

        Unregister-ScheduledTask `
            -Confirm:$false `
            -TaskName $tskName `
            -ErrorAction SilentlyContinue
        Register-ScheduledTask `
            -TaskName $tskName `
            -Action (
                New-ScheduledTaskAction `
                    -Execute 'cleanmgr.exe' `
                    -Argument '/sagerun:9999'
            ) `
            -RunLevel Highest `
            -User 'SYSTEM' `
            -Force 1> $null

        Write-Host "[$(Get-Date -Format 'o')] Cleaning up Disk..."
        Start-ScheduledTask -TaskName $tskName
        do {
            Start-Sleep -Seconds 5
            $tskRes      =  (Get-ScheduledTaskInfo -TaskName $tskName).LastTaskResult
            $tskState    =  (Get-ScheduledTask    -TaskName $tskName).State
        } until (
            $tskRes -notin @(0x41303, 0x41301) -and
            $tskState -notin @('Queued', 'Running')
        )
        if ($tskRes) {throw "The ``cleanmgr.exe`` failed: 0x$('{0:X8}' -f $tskRes)"}
        Write-Host "[$(Get-Date -Format 'o')] Done."
    } finally {
        Unregister-ScheduledTask `
            -Confirm:$false `
            -TaskName $tskName `
            -ErrorAction SilentlyContinue
        $handlers | ForEach-Object -Process {
            Remove-ItemProperty `
                -Path $_.PSPath `
                -Name $flag `
                -ErrorAction SilentlyContinue
        }
    }
}
```
</details>
</details>
<details><summary>Generalize</summary>

**Pre-requisites:**
  - <details><summary>Create common <code>unattend</code> files.</summary>
    <details><summary><strong>Notes:</strong></summary>

      - The `unattend` parser handling for `<Path>` (`RunSynchronous` and `RunAsynchronous`) and `<CommandLine>`
        (`FirstLogonCommands`):
          - Limits:
              - `<Path>`: Single-line with max. 259 characters.
              - `<CommandLine>`: Multi-line with total max. 1024 characters.
          - Lines (the full content of the XML element value) are parsed as whole string and used as the
            `lpCommandLine` argument of `CreateProcessW()`. In turn, it will be passed as is to the child process.
            It is up to the child process how to parse the arguments:
              - Windows CRT `CommandLineToArgvW()`.
                  - Tokenized with white-space as delimiter.
                  - An unescaped Double-Quote pair preserves white-spaces in between. Unbalanced Double-Quote pair is
                    considered closed at the end of parsing.
                  - Escape character is `\`, with the following rules:
                      - Odd number of consecutive `\` preceding `"`: each preceding pair `\\`, if any, becomes literal
                        `\` and the last `\"` becomes literal `"`.
                      - Even number of consecutive `\` preceding `"`: each preceding pair `\\` becomes literal `\` and
                        the last `"` becomes either the opening or closing Unescaped Double-Quote pair.
                  - First token is the executable (child's `argv[0]`), the remaining are arguments (child's
                    `argv[1:]`).
                  - Pattern `%...EnvVarName...%` will be replaced with the corresponding Env. Var. value, if defined.
                    Otherwise it remain as literal.
              - Windows `cmd.exe`:
                  - Read Microsoft official documentation.
      - The `RunSynchronous` / `RunAsynchronous` (`Microsoft-Windows-Deployment`) are valid in:
        `windowsPE`, `offlineServicing`, `generalize`, `specialize`, and `auditUser`.
      - The `FirstLogonCommands` are valid in: `oobe`.
    </details>

    Run in PowerShell as `Administrator`:
    ```powershell
    & {
        function GenRndPwd {
            $chars  = [char[]]((97..122) + (65..90) + (48..57)) + '+=._-'.ToCharArray()
            $rng    = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
            $bytes  = [byte[]]::new(256)
            try {
                do {
                    $rng.GetBytes($bytes)
                    $pwd = -join (
                        $bytes |
                        ForEach-Object -Process {$chars[$_ % $chars.Length]} |
                        Select-Object -First 32
                    )
                } until (
                    ($pwd.Length -ge 32) -and
                    ($pwd -cmatch '[A-Z]') -and
                    ($pwd -cmatch '[a-z]') -and
                    ($pwd  -match '[0-9]') -and
                    ($pwd  -match '[+=._-]')
                )
                $pwd
            } finally {
                $rng.Dispose()
            }
        }

        # Administrator.
        $admPwd = 'win-adm'

        # Local User.
        $crdUsr = 'qa-usr'
        $crdPwd = GenRndPwd
        $dispName = 'QA User'

        # Create `Script--System--SetWinUpd.ps1`.
        New-Item `
            -ItemType Directory `
            -Path "${env:ProgramData}\Scripts" `
            -Force 1> $null
        Set-Content `
            -Path "${env:ProgramData}\Scripts\Script--System--SetWinUpd.ps1" `
            -Encoding UTF8 -NoNewline `
            -Value (@'
    # Pause Windows Update.
    $wuaUXregRoot    =  'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $wuaPolRegRoot   =  'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings'
    $nowUTC          =  (Get-Date).ToUniversalTime()
    @(
        'PauseFeatureUpdatesStartTime',
        'PauseQualityUpdatesStartTime',
        'PauseUpdatesStartTime'
    ) | ForEach-Object -Process {
        Set-ItemProperty `
            -Path $wuaUXregRoot `
            -Name $_ `
            -Type String -Value $nowUTC.ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    @(
        'PauseFeatureUpdatesEndTime',
        'PauseQualityUpdatesEndTime',
        'PauseUpdatesExpiryTime'
    ) | ForEach-Object -Process {
        Set-ItemProperty `
            -Path $wuaUXregRoot `
            -Name $_ `
            -Type String -Value $nowUTC.AddDays(365).ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    @(
        'PausedFeatureDate',
        'PausedQualityDate'
    ) | ForEach-Object -Process {
        Set-ItemProperty `
            -Path $wuaPolRegRoot `
            -Name $_ `
            -Type String -Value $nowUTC.ToString("yyyy-MM-dd HH:mm:ss") `
            -ErrorAction Stop
    }
    @(
        'PausedFeatureStatus',
        'PausedQualityStatus'
    ) | ForEach-Object -Process {
        Set-ItemProperty `
            -Path $wuaPolRegRoot `
            -Name $_ `
            -Type DWord -Value 1 `
            -ErrorAction Stop
    }
    Stop-Service -Name wuauserv -Force -ErrorAction Stop
    exit 0
    '@ + "`n")

        # Create `Script--Specialize--SetWinUpd.ps1`.
        Set-Content `
            -Path "${env:SystemRoot}\System32\Sysprep\Script--Specialize--SetWinUpd.ps1" `
            -Encoding UTF8 -NoNewline `
            -Value (@'
    Start-Transcript -Path "${env:SystemRoot}\Panther\unattend--specialize.log" -Append -Force

    & "${env:ProgramData}\Scripts\Script--System--SetWinUpd.ps1"

    Remove-Item -Path $PSCommandPath -Force
    Stop-Transcript
    exit 0
    '@ + "`n")

        # Create `Script--Specialize--SetLocale.ps1`.
        Set-Content `
            -Path "${env:SystemRoot}\System32\Sysprep\Script--Specialize--SetLocale.ps1" `
            -Encoding UTF8 -NoNewline `
            -Value (@'
    Start-Transcript -Path "${env:SystemRoot}\Panther\unattend--specialize.log" -Append -Force

    $key = 'Registry::HKU\.DEFAULT\Control Panel\International'

    Set-ItemProperty -Path $key -Name sShortDate    -Type String -Value 'yyyy-MM-dd'
    Set-ItemProperty -Path $key -Name sLongDate     -Type String -Value 'dddd, MMMM d, yyyy'
    Set-ItemProperty -Path $key -Name sShortTime    -Type String -Value 'HH:mm'
    Set-ItemProperty -Path $key -Name sTimeFormat   -Type String -Value 'HH:mm:ss'

    Remove-Item -Path $PSCommandPath -Force
    Stop-Transcript
    exit 0
    '@ + "`n")

        # Create `Script--Specialize--SetSysEnv.ps1`.
        Set-Content `
            -Path "${env:SystemRoot}\System32\Sysprep\Script--Specialize--SetSysEnv.ps1" `
            -Encoding UTF8 -NoNewline `
            -Value (@'
    Start-Transcript -Path "${env:SystemRoot}\Panther\unattend--specialize.log" -Append -Force

    # Prepend `%SystemDrive%\BIN` to the system-wide PATH.
    $sysEnvRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    Set-ItemProperty `
        -Path $sysEnvRegPath `
        -Name 'Path' `
        -Type ExpandString -Value (
            '%SystemDrive%\BIN;' + (Get-Item $sysEnvRegPath).GetValue(
                'Path',
                '',
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
        )

    Remove-Item -Path $PSCommandPath -Force
    Stop-Transcript
    exit 0
    '@ + "`n")

        # Create `Script--Specialize--SetPostOOBE.ps1`.
        Set-Content `
            -Path "${env:SystemRoot}\System32\Sysprep\Script--Specialize--SetPostOOBE.ps1" `
            -Encoding UTF8 -NoNewline `
            -Value (@'
    Start-Transcript -Path "${env:SystemRoot}\Panther\unattend--specialize.log" -Append -Force

    # PostOOBE hook registration.
    $tskName             =  'PostOOBE'
    $postOOBEregRoot     =  'HKLM:\SYSTEM\Setup\FirstBoot\PostOOBE'
    $postOOBEregKey      =  $($key = (
                                (
                                    Get-Item `
                                        -Path $postOOBEregRoot `
                                        -ErrorAction SilentlyContinue
                                ).Property |
                                Where-Object -FilterScript {$_ -match '^\d+$'} |
                                ForEach-Object -Process {[int]$_} |
                                Measure-Object -Maximum
                            ).Maximum; if ($key -eq $null) {0} else {(++$key)})
    $postOOBEscripts     =  @()

    # Initialize System (`--0x--`).
    . {
        # Create `Script--PostOOBE--01--InitSystem--CloudBase-Init.ps1`.
        Set-Content `
            -Path "${env:SystemRoot}\System32\Sysprep\Script--PostOOBE--01--InitSystem--CloudBase-Init.ps1" `
            -Encoding UTF8 -NoNewline `
            -Value ([string]::Join("`n", @({
    (
        Get-Service `
            -Name 'cloudbase-init' `
            -ErrorAction SilentlyContinue
    ) | ForEach-Object -Process {
        # Ensure the Service not running while being modified.
        Set-Service -Name $_.Name -StartupType Manual
        while ((Get-Service -Name $_.Name).Status -eq 'Running') {
            Start-Sleep -Seconds 1
        }

        # The CloudBase-Init set the Host Name too early as Windows set it
        #   after `RunSynchronous` execution. Redo at OOBE boot.
        Get-ChildItem `
            -Path 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init' |
        ForEach-Object -Process {
            Remove-ItemProperty `
                -Path "$($_.PSPath)\Plugins" `
                -Name SetHostNamePlugin `
                -ErrorAction SilentlyContinue
        }

        # Re-grant required privileges to `cloudbase-init` Service Account.
        $cbiSID  =  (New-Object System.Security.Principal.NTAccount($_.Name)).
                        Translate(
                            [System.Security.Principal.SecurityIdentifier]
                        ).Value
        $tmpInf  =  "${env:TEMP}\sys-sec.inf"
        $tmpDB   =  "${env:TEMP}\sys-sec.sdb"
        SecEdit.exe /quiet /export /cfg $tmpInf
        . {
            (
                Get-Content -Path $tmpInf
            )   -replace '(^SeServiceLogonRight = .*)',             ('$1,*' + $cbiSID) `
                -replace '(^SeAssignPrimaryTokenPrivilege = .*)',   ('$1,*' + $cbiSID) `
                -replace '(^SeIncreaseQuotaPrivilege = .*)',        ('$1,*' + $cbiSID) |
            Set-Content -Path $tmpInf -Encoding Unicode
        }
        secedit /quiet /configure /db $tmpDB /cfg $tmpInf /areas USER_RIGHTS
        Remove-Item -Path @($tmpInf, $tmpDB) -Force -ErrorAction SilentlyContinue

        # Run CloudBase-Init once with `allow_reboot=false`.
        $cbiCfg  =  $(
                        (
                            Get-ItemProperty `
                                -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.Name)"
                        ).ImagePath -match '--config-file\s+"([^"]+)"' 1> $null
                        $Matches[1]
                    )
        $tmpCfg  =  "${env:TEMP}\cbi.conf"
        @(
            (Get-Content -Path $cbiCfg | Where-Object -FilterScript {
                $_ -notmatch '^\s*allow_reboot\s*='
            }),
            'allow_reboot=false'
        ) | Set-Content -Path $tmpCfg -Encoding Ascii
        & "$(Split-Path -Path (
            Split-Path -Path $cbiCfg -Parent
        ) -Parent)\Python\Scripts\cloudbase-init.exe" `
            --config-file $tmpCfg
        Remove-Item -Path $tmpCfg -Force -ErrorAction SilentlyContinue

        # Ensure the Service starts automatically on next boot.
        Set-Service -Name $_.Name -StartupType Automatic

        # Request reboot if pending hostname differs from active.
        if ((Get-ItemProperty `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'
        ).ComputerName -ne [System.Net.Dns]::GetHostName()) {exit 2}
    }
            }, {
    exit 0
            })) + "`n")
        ### ^^^ Script--PostOOBE--01--InitSystem--CloudBase-Init.ps1     ^^^ ###
        $postOOBEscripts +=
            "${env:SystemRoot}\System32\Sysprep\Script--PostOOBE--01--InitSystem--CloudBase-Init.ps1"
    }

    # Configure System Core Settings (`--1x--`).
    . {
        # Create `Script--PostOOBE--10--ConfSystemCore.ps1` worker script.
        Set-Content `
            -Path "${env:SystemRoot}\System32\Sysprep\Script--PostOOBE--10--ConfSystemCore--exec.ps1" `
            -Encoding UTF8 -NoNewline `
            -Value ([string]::Join("`n", @({
    Start-Transcript -Path "${env:SystemRoot}\Panther\unattend--PostOOBE--10--ConfSystemCore.log" -Append -Force
            }, {
    # Configure SSH.
    & {
        # Generate SSH key pair for `Administrator`.
        $admSSHdir = "${env:USERPROFILE}\.ssh"
        New-Item -ItemType Directory -Path $admSSHdir -Force 1> $null
        @('ed25519') | ForEach-Object -Process {
            if (-not (Test-Path -Path "${admSSHdir}\id_${_}")) {
                ssh-keygen -q -t $_ -f "${admSSHdir}\id_${_}" -N '""'
            }
        }

        # Allow `Administrator` to SSH to localhost as other users.
        $usrProfRoot     =  Split-Path -Path ${env:USERPROFILE} -Parent
        $pubKeys         =  @(
            Get-ChildItem -Path $admSSHdir -Filter '*.pub' -File |
            ForEach-Object -Process {Get-Content -Path $_.FullName}
        )
        $pubKeyBodies    =  @($pubKeys | ForEach-Object -Process {($_ -split ' ')[1]})
        @('qa-usr') | ForEach-Object -Process {
            $usrID = $_
            if (
                Get-LocalGroupMember -Group 'Administrators' |
                Where-Object -FilterScript {$_.Name -like "*\${usrID}"}
            ) {
                $authFile    =  "${env:ProgramData}\ssh\administrators_authorized_keys"
                $usrACL      =  ''
            } else {
                $sshDir = "${usrProfRoot}\${usrID}\.ssh"
                New-Item -ItemType Directory -Path $sshDir -Force 1> $null
                $acl = Get-Acl -Path $sshDir
                $acl.SetOwner([System.Security.Principal.NTAccount]$usrID)
                Set-Acl -Path $sshDir -AclObject $acl
                $authFile    =  "${sshDir}\authorized_keys"
                $usrACL      =  "${usrID}:(M)"
            }
            $lines = @($(if (Test-Path -Path $authFile) {
                Get-Content -Path $authFile |
                Where-Object -FilterScript {($_ -split ' ')[1] -notin $pubKeyBodies}
            } else {@()}))
            ($pubKeys + $lines) | Set-Content $authFile -Encoding Ascii
            if ($usrACL) {
                $acl = Get-Acl -Path $authFile
                $acl.SetOwner([System.Security.Principal.NTAccount]$usrID)
                Set-Acl -Path $authFile -AclObject $acl
            }
            . {
                icacls.exe $authFile /reset
                icacls.exe $authFile `
                    /inheritance:r `
                    /grant:r `
                        $usrACL `
                        'BUILTIN\Administrators:(F)' `
                        'NT AUTHORITY\SYSTEM:(F)'
            } 1> $null
        }
    }

    # Clean Stale SIDs on Windows Application Database (AppX).
    & {
    }
            }, {
    Remove-Item $PSCommandPath
    Stop-Transcript
    exit 0
            })) + "`n")
        ### ^^^ Script--PostOOBE--10--ConfSystemCore--exec.ps1           ^^^ ###

        # Create `Script--PostOOBE--10--ConfSystemCore.ps1`.
        Set-Content `
            -Path "${env:SystemRoot}\System32\Sysprep\Script--PostOOBE--10--ConfSystemCore.ps1" `
            -Encoding UTF8 -NoNewline `
            -Value
    '@ + " (@'`n" + @"
    Set-LocalUser ``
        -Name 'Administrator' ``
        -Password (ConvertTo-SecureString '$(
            [System.Management.Automation.Language.CodeGeneration]::`
            EscapeSingleQuotedStringContent(${admPwd})
        )' -AsPlainText -Force)
    "@ + "`n" + @'

    # Schedule a Task.
    $tskName = 'PostOOBE--ConfSystemCore'
    while ((
        Get-Service -Name 'Schedule' -ErrorAction SilentlyContinue
    ).Status -ne 'Running') {
        Start-Sleep -Seconds 2
    }
    Unregister-ScheduledTask `
        -Confirm:$false `
        -TaskName $tskName `
        -ErrorAction SilentlyContinue
    Register-ScheduledTask `
        -TaskName $tskName `
        -Action (
            New-ScheduledTaskAction `
                -Execute 'powershell.exe' `
                -Argument (
                    '-NoProfile ' +
                    '-NonInteractive ' +
                    '-WindowStyle Hidden ' +
                    '-File "%SystemRoot%\System32\Sysprep\Script--PostOOBE--10--ConfSystemCore--exec.ps1"'
                )
        ) `
        -RunLevel Highest `
        -User 'Administrator' `
    '@ + "`n" + @"
        -Password '$(
            [System.Management.Automation.Language.CodeGeneration]::`
            EscapeSingleQuotedStringContent(${admPwd})
        )' ``
    "@ + "`n" + @'
        -Force 1> $null

    # Execute the Task.
    Start-ScheduledTask -TaskName $tskName
    do {
        Start-Sleep -Seconds 5
        $tskRes      =  (Get-ScheduledTaskInfo -TaskName $tskName).LastTaskResult
        $tskState    =  (Get-ScheduledTask -TaskName $tskName).State
        Write-Host "[$(
            Get-Date -Format 'o'
        )] PostOOBE task executed with exit code: 0x$(
            '{0:X8}' -f $tskRes
        ) [current state: ${tskState}]"
    } until (
        $tskRes -notin @(0x41303, 0x41301) -and
        $tskState -notin @('Queued', 'Running')
    )

    # Remove the Task.
    Unregister-ScheduledTask `
        -Confirm:$false `
        -TaskName $tskName `
        -ErrorAction SilentlyContinue

    exit 0
    '@ + "`n'@ + `"``n`")`n" + @'
        ### ^^^ Script--PostOOBE--10--ConfSystemCore.ps1                 ^^^ ###
        $postOOBEscripts +=
            "${env:SystemRoot}\System32\Sysprep\Script--PostOOBE--10--ConfSystemCore.ps1"
    }

    # Configure System User Preferences (`--2x--`).
    . {
    }

    # Configure Applications (`--3x--`).
    . {
    }

    $postOOBEscripts = @(
        $postOOBEscripts |
        Where-Object -FilterScript {
            [IO.Path]::GetFileName($_) -match '^Script--PostOOBE--\d+--'
        } |
        Sort-Object -Property {
            [IO.Path]::GetFileName($_) -match '^\D+--(\d+)--' 1> $null
            [int]$Matches[1]
        }
    )

    # Create `PostOOBE` worker script.
    Set-Content `
        -Path "${env:SystemRoot}\System32\Sysprep\Script--PostOOBE--exec.ps1" `
        -Encoding UTF8 -NoNewline `
        -Value ([string]::Join("`n", @({
    function Reboot {
        Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList @(
                '-NoProfile',
                '-NonInteractive',
                '-WindowStyle', 'Hidden',
                '-Command', '"Start-Sleep -Seconds 5; Restart-Computer -Force"'
            )
    }

    '@ + "`n" + @"
    function GenRndPwd {${Function:GenRndPwd}}

    Set-LocalUser ``
        -Name 'Administrator' ``
        -Password (ConvertTo-SecureString '$(
            [System.Management.Automation.Language.CodeGeneration]::`
            EscapeSingleQuotedStringContent(${admPwd})
        )' -AsPlainText -Force)
    "@ + "`n" + @'

    Start-Transcript -Path "${env:SystemRoot}\Panther\unattend--PostOOBE--exec.log" -Append -Force
        }, "
    `$tskName             =  '$(
                                [System.Management.Automation.Language.CodeGeneration]::`
                                EscapeSingleQuotedStringContent($tskName)
                            )'
    `$postOOBEscripts     =  @(
                                '$(
                                    ($postOOBEscripts | ForEach-Object -Process {
                                        [System.Management.Automation.Language.CodeGeneration]::`
                                        EscapeSingleQuotedStringContent($_)
                                    }) -join ("',`n" + (' ' * 28) + "'")
                                )'
                            )
        ", {
    $pendingReboot = $false
    $postOOBEscripts | ForEach-Object -Process {if (Test-Path -Path $_) {
        Write-Host "[$(
            Get-Date -Format 'o'
        )] Executing ``${_}``..."
        & $_
        Write-Host "[$(
            Get-Date -Format 'o'
        )] The ``${_}`` exit code: ${LASTEXITCODE}"
        $script = $_
        switch ($LASTEXITCODE) {
            0   {Remove-Item -Path $script -Force}
            1   {Rename-Item -Path $script -NewName "$script.0" -Force}
            2   {Remove-Item -Path $script -Force; Reboot; exit 0}
            3   {Remove-Item -Path $script -Force; $pendingReboot = $true}
        }
    }}

    # Remove `PostOOBE` Task.
    Unregister-ScheduledTask `
        -Confirm:$false `
        -TaskName $tskName `
        -ErrorAction SilentlyContinue
        }, {
    Remove-Item -Path $PSCommandPath -Force
    Stop-Transcript

    # Randomize `Administrator` password.
    & {
        Set-LocalUser `
            -Name 'Administrator' `
            -Password (ConvertTo-SecureString $(GenRndPwd) -AsPlainText -Force)
    }

    if ($pendingReboot) {Reboot}
    exit 0
        })) + "`n")
    ### ^^^ Script--PostOOBE--exec.ps1                                   ^^^ ###

    # Create `PostOOBE` script.
    Set-Content `
        -Path "${env:SystemRoot}\System32\Sysprep\Script--PostOOBE.ps1" `
        -Encoding UTF8 -NoNewline `
        -Value
    '@ + " (@'`n" + @'
    Start-Transcript -Path "${env:SystemRoot}\Panther\unattend--PostOOBE.log" -Append -Force

    '@ + "`n'@ + `"``n`" + @`"`n" + @'
    `$tskName             =  '$(
                                [System.Management.Automation.Language.CodeGeneration]::`
                                EscapeSingleQuotedStringContent($tskName)
                            )'
    '@ + "`n`"@ + `"``n`" + @'`n" + @'

    # Schedule `PostOOBE` Task.
    while ((
        Get-Service -Name 'Schedule' -ErrorAction SilentlyContinue
    ).Status -ne 'Running') {
        Start-Sleep -Seconds 2
    }
    Unregister-ScheduledTask `
        -Confirm:$false `
        -TaskName $tskName `
        -ErrorAction SilentlyContinue
    Register-ScheduledTask `
        -TaskName $tskName `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Action (
            New-ScheduledTaskAction `
                -Execute 'powershell.exe' `
                -Argument (
                    '-NoProfile ' +
                    '-NonInteractive ' +
                    '-WindowStyle Hidden ' +
                    '-File "%SystemRoot%\System32\Sysprep\Script--PostOOBE--exec.ps1"'
                )
        ) `
        -RunLevel Highest `
        -User 'SYSTEM' `
        -Force 1> $null

    # Execute the Task directly (Task Scheduler will pick it up if there are
    #   reboots).
    (
        Start-Process `
            -PassThru `
            -FilePath 'powershell.exe' `
            -ArgumentList @(
                '-NoProfile',
                '-NonInteractive',
                '-WindowStyle', 'Hidden',
                '-File', "`"${env:SystemRoot}\System32\Sysprep\Script--PostOOBE--exec.ps1`""
            )
    ).WaitForExit()

    # Remove `PostOOBE` hook.
    '@ + "`n'@ + `"``n`" + @`"`n" + @'
    Remove-ItemProperty ``
        -Path '$(
            [System.Management.Automation.Language.CodeGeneration]::`
            EscapeSingleQuotedStringContent($postOOBEregRoot)
        )' ``
        -Name '$(
            [System.Management.Automation.Language.CodeGeneration]::`
            EscapeSingleQuotedStringContent($postOOBEregKey)
        )' ``
        -Force -ErrorAction SilentlyContinue
    '@ + "`n`"@ + `"``n`" + @'`n" + @'

    Remove-Item -Path $PSCommandPath -Force
    Stop-Transcript
    exit 0
    '@ + "`n'@ + `"``n`")`n" + @'
    ### ^^^ Script--PostOOBE.ps1                                         ^^^ ###

    # Register `PostOOBE` hook.
    #   Need to execute in detached mode, so a Task (to be able to continue if
    #   immediate reboot is requested by Child Tasks) can be scheduled (need
    #   `Schedule` Service to run).
    Set-ItemProperty `
        -Path $postOOBEregRoot `
        -Name ([string]$postOOBEregKey) `
        -Type String -Value (
            "powershell.exe " +
            "-NoProfile " +
            "-NonInteractive " +
            "-WindowStyle Hidden " +
            '-Command "' +
                'Start-Process ' +
                "-FilePath 'powershell.exe' " +
                '-ArgumentList @(' +
                    "'-NoProfile', " +
                    "'-NonInteractive', " +
                    "'-WindowStyle', 'Hidden', " +
                    "'-File', " + '\"`\"' +
                        '${env:SystemRoot}\System32\Sysprep\' +
                        'Script--PostOOBE.ps1' +
                    '`\"\"' +
                ")" +
            '"'
        ) `
        -Force

    Remove-Item -Path $PSCommandPath -Force
    Stop-Transcript
    exit 0
    '@ + "`n")

        # Create Specialize `unattend` file.
        Set-Content `
            -Path "${env:SystemRoot}\System32\Sysprep\unattend--specialize.xml" `
            -Encoding UTF8 -NoNewline `
            -Value (@'
    <?xml version="1.0" encoding="utf-8"?>
    <unattend
        xmlns="urn:schemas-microsoft-com:unattend"
        xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
    >
      <settings pass="specialize">
        <component
          name="Microsoft-Windows-SecureStartup-FilterDriver"
          processorArchitecture="amd64"
          publicKeyToken="31bf3856ad364e35"
          language="neutral"
          versionScope="nonSxS"
        >
          <PreventDeviceEncryption>true</PreventDeviceEncryption>
        </component>
        <component
          name="Microsoft-Windows-Deployment"
          processorArchitecture="amd64"
          publicKeyToken="31bf3856ad364e35"
          language="neutral"
          versionScope="nonSxS"
        >
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add">
              <Order>10</Order>
              <Path>NET USER Administrator /ACTIVE:YES</Path>
              <WillReboot>Never</WillReboot>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>11</Order>
              <Path>NET ACCOUNTS /MAXPWAGE:UNLIMITED</Path>
              <WillReboot>Never</WillReboot>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>12</Order>
              <Path>powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' -Name 'PreventDeviceEncryption' -Type DWord -Value 1; Disable-BitLocker -MountPoint $env:SystemDrive"</Path>
              <WillReboot>Never</WillReboot>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>13</Order>
              <Path>powershell -NoProfile -NonInteractive -WindowStyle Hidden -File "%SystemRoot%\System32\Sysprep\Script--Specialize--SetWinUpd.ps1"</Path>
              <WillReboot>Never</WillReboot>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>20</Order>
              <Path>powershell -NoProfile -NonInteractive -WindowStyle Hidden -File "%SystemRoot%\System32\Sysprep\Script--Specialize--SetLocale.ps1"</Path>
              <WillReboot>Never</WillReboot>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>21</Order>
              <Path>powershell -NoProfile -NonInteractive -WindowStyle Hidden -File "%SystemRoot%\System32\Sysprep\Script--Specialize--SetSysEnv.ps1"</Path>
              <WillReboot>Never</WillReboot>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>30</Order>
              <Path>powershell -NoProfile -NonInteractive -WindowStyle Hidden -File "%SystemRoot%\System32\Sysprep\Script--Specialize--SetPostOOBE.ps1"</Path>
              <WillReboot>Never</WillReboot>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
    </unattend>
    '@ + "`n")

        # Create OOBE `unattend` file.
        Set-Content `
            -Path "${env:SystemRoot}\System32\Sysprep\unattend--oobe.xml" `
            -Encoding UTF8 -NoNewline `
            -Value (@'
    <?xml version="1.0" encoding="utf-8"?>
    <unattend
        xmlns="urn:schemas-microsoft-com:unattend"
        xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
    >
      <settings pass="oobeSystem">
        <component
          name="Microsoft-Windows-Shell-Setup"
          processorArchitecture="amd64"
          publicKeyToken="31bf3856ad364e35"
          language="neutral"
          versionScope="nonSxS"
        >
          <OOBE>
            <HideEULAPage>true</HideEULAPage>
            <HideLocalAccountScreen>true</HideLocalAccountScreen>
            <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
            <SkipMachineOOBE>true</SkipMachineOOBE>
            <SkipUserOOBE>true</SkipUserOOBE>
          </OOBE>
          <AutoLogon>
    '@ + "`n" + @"
            <Username>${crdUsr}</Username>
            <Password>
              <Value>$(
                [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("${crdPwd}Password"))
              )</Value>
    "@ + "`n" + @'
              <PlainText>false</PlainText>
            </Password>
            <Enabled>true</Enabled>
          </AutoLogon>
          <UserAccounts>
            <LocalAccounts>
              <LocalAccount wcm:action="add">
    '@ + "`n" + @"
                <Name>${crdUsr}</Name>
                <DisplayName>${dispName}</DisplayName>
                <Password>
                  <Value>$(
                    [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("${crdPwd}Password"))
                  )</Value>
    "@ + "`n" + @'
                  <PlainText>false</PlainText>
                </Password>
                <Group>Administrators</Group>
              </LocalAccount>
            </LocalAccounts>
          </UserAccounts>
          <FirstLogonCommands>
            <SynchronousCommand wcm:action="add">
              <Order>10</Order>
              <CommandLine>powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "
                Start-Transcript -Path \"${env:SystemRoot}\Panther\unattend--oobe.log\" -Append -Force
                Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoLogonCount -ErrorAction SilentlyContinue
                Stop-Transcript
              "</CommandLine>
              <RequiresUserInput>false</RequiresUserInput>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>20</Order>
              <CommandLine>powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "
                Start-Transcript -Path \"${env:SystemRoot}\Panther\unattend--oobe.log\" -Append -Force
                $key = 'HKCU:\Control Panel\International'
                Set-ItemProperty -Path $key -Name sShortDate    -Type String -Value 'yyyy-MM-dd'
                Set-ItemProperty -Path $key -Name sLongDate     -Type String -Value 'dddd, MMMM d, yyyy'
                Set-ItemProperty -Path $key -Name sShortTime    -Type String -Value 'HH:mm'
                Set-ItemProperty -Path $key -Name sTimeFormat   -Type String -Value 'HH:mm:ss'
                Stop-Transcript
              "</CommandLine>
              <RequiresUserInput>false</RequiresUserInput>
            </SynchronousCommand>
          </FirstLogonCommands>
        </component>
      </settings>
    </unattend>
    '@ + "`n")
    }
    ```
    </details>
  - <details><summary>Stale SID CleanUp on Windows Application Database (Pre-SysPrep).</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    & {
        $svcNames = @('StateRepository', 'AppXSvc', 'ClipSVC', 'InstallService')

        # Force logoff all User Sessions.
        :outer for ($i = 3; $i; $i--) {
            (QUERY USER 2> $null) | Select-Object -Skip 1 | ForEach-Object -Process {
                if ($_ -match '^\s*\S+\s+?\S*?\s+(\d+)\s') {LOGOFF $Matches[1]}
            }
            for ($j = 6; $j; $j--) {
                Start-Sleep -Seconds 5
                if (-not (QUERY USER 2> $null)) {break outer}
            }
        }
        if (-not $i) {
            Write-Error -Message 'Timed out waiting for all User Sessions to log off.'
            exit 1
        }

        $svcNames | ForEach-Object -Process {
            Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue
        }

        $dbSrc   =  "${env:ProgramData}\Microsoft\Windows\AppRepository\StateRepository-Machine.srd"
        $dbDir   =  "${env:TEMP}\dbDir"
        $dbPath  =  "${dbDir}\StateRepository-Machine.srd"

        # Copy DB to a working directory.
        Remove-Item -Path $dbDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $dbDir -Force 1> $null
        Copy-Item -Path "${dbSrc}*" -Destination $dbDir -Force

        # Load `winsqlite3.dll` with stub functions registered.
        Add-Type -TypeDefinition (@'
    using System;
    using System.Collections.Generic;
    using System.Runtime.InteropServices;
    public class WinSqlite {
        const string Dll                 =  "winsqlite3.dll";
        const int SQLITE_OK              =  0;
        const int SQLITE_ROW             =  100;
        const int SQLITE_OPEN_READONLY   =  1;
        const int SQLITE_OPEN_READWRITE  =  2;
        const int SQLITE_UTF8            =  1;

        [DllImport(Dll)] public static extern int sqlite3_open_v2(string filename, out IntPtr db, int flags, string vfs);
        [DllImport(Dll)] public static extern int sqlite3_prepare_v2(IntPtr db, string sql, int nBytes, out IntPtr stmt, IntPtr tail);
        [DllImport(Dll)] public static extern int sqlite3_step(IntPtr stmt);
        [DllImport(Dll)] public static extern int sqlite3_column_int(IntPtr stmt, int col);
        [DllImport(Dll)] public static extern int sqlite3_column_bytes(IntPtr stmt, int col);
        [DllImport(Dll)] public static extern IntPtr sqlite3_column_blob(IntPtr stmt, int col);
        [DllImport(Dll)] public static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport(Dll)] public static extern IntPtr sqlite3_column_text(IntPtr stmt, int col);
        [DllImport(Dll)] public static extern long sqlite3_column_int64(IntPtr stmt, int col);
        [DllImport(Dll)] public static extern int sqlite3_exec(IntPtr db, string sql, IntPtr cb, IntPtr arg, out IntPtr errmsg);
        [DllImport(Dll)] public static extern int sqlite3_create_function_v2(
            IntPtr db, string name, int nArg, int eTextRep, IntPtr pApp, SQLiteFunc xFunc, IntPtr xStep, IntPtr xFinal, IntPtr xDestroy
        );
        [DllImport(Dll)] public static extern void sqlite3_result_int(IntPtr ctx, int val);
        [DllImport(Dll)] public static extern void sqlite3_result_text(IntPtr ctx, string val, int n, IntPtr destructor);
        [DllImport(Dll)] public static extern int sqlite3_close_v2(IntPtr db);
        public delegate void SQLiteFunc(IntPtr ctx, int argc, IntPtr argv);
        public static void ReturnZero(IntPtr ctx, int argc, IntPtr argv) {sqlite3_result_int(ctx, 0);}
        public static void ReturnOne(IntPtr ctx, int argc, IntPtr argv)  {sqlite3_result_int(ctx, 1);}
        public static void ReturnNow(IntPtr ctx, int argc, IntPtr argv)  {
            sqlite3_result_text(ctx, DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss"), -1, new IntPtr(-1));
        }

        public static Tuple<string, long>[] CheckFKoor(string dbPath) {
            IntPtr db;
            if (sqlite3_open_v2(dbPath, out db, SQLITE_OPEN_READONLY, null) != SQLITE_OK) return new Tuple<string,long>[0];
            var results = new List<Tuple<string, long>>();
            try {
                IntPtr stmt;
                if (sqlite3_prepare_v2(db, "PRAGMA foreign_key_check;", -1, out stmt, IntPtr.Zero) == SQLITE_OK) {
                    while (sqlite3_step(stmt) == SQLITE_ROW) {
                        string table = Marshal.PtrToStringAnsi(sqlite3_column_text(stmt, 0));
                        long rowId = sqlite3_column_int64(stmt, 1);
                        results.Add(Tuple.Create(table, rowId));
                    }
                    sqlite3_finalize(stmt);
                }
            } finally {sqlite3_close_v2(db);}
            return results.ToArray();
        }

        public static bool CleanFKoor(string dbPath, Tuple<string, long>[] fkOOR) {
            if (fkOOR.Length == 0) return true;
            IntPtr db;
            if (sqlite3_open_v2(dbPath, out db, SQLITE_OPEN_READWRITE, null) != SQLITE_OK) return false;
            bool ok = true;
            try {
                SQLiteFunc zero = ReturnZero, one = ReturnOne, now = ReturnNow;
                sqlite3_create_function_v2(db, "is_srjournal_enabled",  0, SQLITE_UTF8, IntPtr.Zero, zero,  IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                sqlite3_create_function_v2(db, "is_triggers_enabled",   0, SQLITE_UTF8, IntPtr.Zero, one,   IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                sqlite3_create_function_v2(db, "now",                   0, SQLITE_UTF8, IntPtr.Zero, now,   IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                sqlite3_create_function_v2(db, "workid",                0, SQLITE_UTF8, IntPtr.Zero, zero,  IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                IntPtr stmt;
                foreach (var row in fkOOR) {
                    //  Skip Tables that have child Tables as it will create new orphans.
                    bool hasChildren = false;
                    if (sqlite3_prepare_v2(
                        db,
                        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND sql LIKE '% REFERENCES " + row.Item1 + "(%';",
                        -1, out stmt, IntPtr.Zero
                    ) == SQLITE_OK) {
                        if ((sqlite3_step(stmt) == SQLITE_ROW) && (sqlite3_column_int(stmt, 0) > 0))
                            hasChildren = true;
                        sqlite3_finalize(stmt);
                    }
                    if (hasChildren) continue;

                    //  Collect all FK 'from' Column Names for this Table.
                    var fkCols = new List<string>();
                    if (sqlite3_prepare_v2(
                        db,
                        "PRAGMA foreign_key_list(" + row.Item1 + ");",
                        -1, out stmt, IntPtr.Zero
                    ) == SQLITE_OK) {
                        while (sqlite3_step(stmt) == SQLITE_ROW)
                            fkCols.Add(Marshal.PtrToStringAnsi(sqlite3_column_text(stmt, 3)));
                        sqlite3_finalize(stmt);
                    }
                    if (fkCols.Count == 0) continue;

                    //  Skip only if ALL FK Column values are 0 (every ref. is sentinel/default).
                    bool allSentinel = true;
                    foreach (var col in fkCols) {
                        if (sqlite3_prepare_v2(
                            db,
                            "SELECT " + col + " FROM " + row.Item1 + " WHERE rowid=" + row.Item2 + ";",
                            -1, out stmt, IntPtr.Zero
                        ) == SQLITE_OK) {
                            if ((sqlite3_step(stmt) == SQLITE_ROW) && (sqlite3_column_int(stmt, 0) != 0))
                                allSentinel = false;
                            sqlite3_finalize(stmt);
                        }
                        if (!allSentinel) break;
                    }
                    if (allSentinel) continue;

                    IntPtr errmsg;
                    if (sqlite3_exec(
                        db,
                        "DELETE FROM " + row.Item1 + " WHERE rowid=" + row.Item2 + ";",
                        IntPtr.Zero, IntPtr.Zero, out errmsg
                    ) != SQLITE_OK) {
                        Console.Error.WriteLine(
                            "FK cleanup error (" + row.Item1 + " rowid=" + row.Item2 + "): " +
                            Marshal.PtrToStringAnsi(errmsg)
                        );
                        ok = false;
                    }
                }
            } finally {sqlite3_close_v2(db);}
            return ok;
        }

        public static Tuple<int, string>[] GetStaleUserIDs(string dbPath, string[] validSids) {
            IntPtr db;
            if (sqlite3_open_v2(dbPath, out db, SQLITE_OPEN_READONLY, null) != SQLITE_OK) return new Tuple<int,string>[0];
            var stale = new List<Tuple<int, string>>();
            try {
                IntPtr stmt;
                if (sqlite3_prepare_v2(db, "SELECT _UserID, UserSid FROM User", -1, out stmt, IntPtr.Zero) == SQLITE_OK) {
                    while (sqlite3_step(stmt) == SQLITE_ROW) {
                        int id = sqlite3_column_int(stmt, 0);
                        int len = sqlite3_column_bytes(stmt, 1);
                        IntPtr ptr = sqlite3_column_blob(stmt, 1);
                        byte[] blob = new byte[len];
                        Marshal.Copy(ptr, blob, 0, len);
                        var sid = new System.Security.Principal.SecurityIdentifier(blob, 0);
                        if (sid.Value.StartsWith("S-1-5-21-") && Array.IndexOf(validSids, sid.Value) < 0)
                            stale.Add(Tuple.Create(id, sid.Value));
                    }
                    sqlite3_finalize(stmt);
                }
            } finally {sqlite3_close_v2(db);}
            return stale.ToArray();
        }

        private class TblDef {
            public string name, pkCol, fkCol;
            public TblDef[] kids;
            public TblDef(string n, string pk, string fk, params TblDef[] ks) {
                name=n; pkCol=pk; fkCol=fk; kids=ks;
            }
        }

        private static void DeleteTree(IntPtr db, string name, string pkCol, string where, TblDef[] kids) {
            IntPtr errmsg, stmt;
            foreach (TblDef kid in kids)
                DeleteTree(
                    db, kid.name, kid.pkCol,
                    kid.fkCol + " IN (SELECT " + pkCol + " FROM " + name + " WHERE " + where + ")",
                    kid.kids
                );
            bool exists = false;
            if (sqlite3_prepare_v2(
                db,
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='" + name + "';",
                -1, out stmt, IntPtr.Zero
            ) == SQLITE_OK) {
                exists = (sqlite3_step(stmt) == SQLITE_ROW);
                sqlite3_finalize(stmt);
            }
            if (!exists) { Console.Error.WriteLine("Schema change: table " + name + " no longer exists."); return; }
            sqlite3_exec(db, "DELETE FROM " + name + " WHERE " + where + ";", IntPtr.Zero, IntPtr.Zero, out errmsg);
        }

        public static bool DeleteStaleUsers(string dbPath, int[] staleIds) {
            IntPtr db;
            if (sqlite3_open_v2(dbPath, out db, SQLITE_OPEN_READWRITE, null) != SQLITE_OK) return false;
            try {
                SQLiteFunc zero = ReturnZero, one = ReturnOne, now = ReturnNow;
                sqlite3_create_function_v2(db, "is_srjournal_enabled",  0, SQLITE_UTF8, IntPtr.Zero, zero,  IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                sqlite3_create_function_v2(db, "is_triggers_enabled",   0, SQLITE_UTF8, IntPtr.Zero, one,   IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                sqlite3_create_function_v2(db, "now",                   0, SQLITE_UTF8, IntPtr.Zero, now,   IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                sqlite3_create_function_v2(db, "workid",                0, SQLITE_UTF8, IntPtr.Zero, zero,  IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                string ids = string.Join(",", staleIds);
                IntPtr errmsg, stmt;

                //  Enable FK checks and collect PackageUser IDs for stale Users.
                sqlite3_exec(db, "PRAGMA foreign_keys=ON;", IntPtr.Zero, IntPtr.Zero, out errmsg);
                var pkgUserIDs = new List<long>();
                if (sqlite3_prepare_v2(
                    db,
                    "SELECT _PackageUserID FROM PackageUser WHERE User IN (" + ids + ");",
                    -1,
                    out stmt,
                    IntPtr.Zero
                ) == SQLITE_OK) {
                    while (sqlite3_step(stmt) == SQLITE_ROW) pkgUserIDs.Add(sqlite3_column_int64(stmt, 0));
                    sqlite3_finalize(stmt);
                }

                //  Delete PackageUser one-at-a-time so Triggers cascade correctly.
                foreach (long pkgUserID in pkgUserIDs) {
                    if (sqlite3_exec(
                        db,
                        "DELETE FROM PackageUser WHERE _PackageUserID=" + pkgUserID + ";",
                        IntPtr.Zero, IntPtr.Zero, out errmsg
                    ) != SQLITE_OK) {
                        Console.Error.WriteLine(
                            "PackageUser delete error (id=" + pkgUserID + "): " + Marshal.PtrToStringAnsi(errmsg)
                        );
                        return false;
                    }
                }

                //  Clean up child Tables not covered by Triggers.
                //      pkCol: Primary Key (PK) of this Table (to build children WHERE).
                //      fkCol: Foreign Key (FK) Col in this Table pointing to parent PK.
                TblDef[] cleanupTables = new TblDef[] {
                    new TblDef(
                        "PackageFamilyUser", "_PackageFamilyUserID", "User",
                        new TblDef("PackageFamilyUserResource", null, "_PackageFamilyUserID")
                    ),
                    new TblDef("PackageSuperceded",         null, "User"),
                    new TblDef("PackageUserStatus",         null, "User"),
                    new TblDef("PrimaryTileUser",           null, "User"),
                    new TblDef("PrimaryTileUserChangelog",  null, "User"),
                    new TblDef("WowDependencyGraph",        null, "User"),
                    new TblDef("SRHistory",                 null, "User"),
                    new TblDef("DependencyGraph",           null, "User")
                };
                foreach (TblDef tbl in cleanupTables)
                    DeleteTree(db, tbl.name, tbl.pkCol, tbl.fkCol + " IN (" + ids + ")", tbl.kids);

                //  Delete stale Users.
                int rc = sqlite3_exec(db, "DELETE FROM User WHERE _UserID IN (" + ids + ");",
                    IntPtr.Zero, IntPtr.Zero, out errmsg);
                if (rc != SQLITE_OK) Console.Error.WriteLine("User delete error: " + Marshal.PtrToStringAnsi(errmsg));
                return (rc == SQLITE_OK);
            } finally {sqlite3_close_v2(db);}
        }

        public static bool Vacuum(string dbPath) {
            IntPtr db, errmsg;
            if (sqlite3_open_v2(dbPath, out db, SQLITE_OPEN_READWRITE, null) != SQLITE_OK) return false;
            try {
                int rc = sqlite3_exec(db, "VACUUM;", IntPtr.Zero, IntPtr.Zero, out errmsg);
                if (rc != SQLITE_OK) Console.Error.WriteLine("Vacuum error: " + Marshal.PtrToStringAnsi(errmsg));
                return (rc == SQLITE_OK);
            } finally {sqlite3_close_v2(db);}
        }
    }
    '@ + "`n")
        $staleIDs = [WinSqlite]::GetStaleUserIDs(
            $dbPath,
            [string[]]@(Get-LocalUser | ForEach-Object -Process {$_.Sid.Value})
        )

        if ($staleIDs) {
            Write-Host "Stale User SIDs: $(($staleIDs | ForEach-Object -Process {$_.Item2}) -join ', ')"
            Write-Host "Success: $([WinSqlite]::DeleteStaleUsers(
                $dbPath,
                [int[]]@($staleIDs | ForEach-Object -Process {$_.Item1})
            ))"
        } else {
            Write-Host "No stale Users found."
        }

        # Compact the DB.
        Write-Host "Vacuum: $([WinSqlite]::Vacuum($dbPath))"

        # Stop services, copy modified DB back, restore ACL, restart services.
        $svcNames | ForEach-Object -Process {
            Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue
        }
        takeown.exe /F $dbSrc /A 1> $null
        icacls.exe $dbSrc /grant 'Administrators:(F)' 1> $null
        Copy-Item -Path "${dbPath}*" -Destination (
            Split-Path -Path $dbSrc -Parent
        ) -Force
        icacls.exe $dbSrc /remove 'Administrators' 1> $null
        icacls.exe $dbSrc /setowner 'NT AUTHORITY\SYSTEM' 1> $null
        $svcNames | ForEach-Object -Process {
            Start-Service -Name $_ -ErrorAction SilentlyContinue
        }
    }
    ```
    </details>
  <!--  DISABLED: Breaks AppX deployment.
  - <details><summary>Stale SID CleanUp on Windows Application Database (Post-OOBE).</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    & {
        $svcNames    =  @('StateRepository', 'AppXSvc', 'ClipSVC', 'InstallService')
        $dbSrc       =  "${env:ProgramData}\Microsoft\Windows\AppRepository\StateRepository-Machine.srd"

        # Force logoff all User Sessions.
        :outer for ($i = 3; $i; $i--) {
            (QUERY USER 2> $null) | Select-Object -Skip 1 | ForEach-Object -Process {
                if ($_ -match '^\s*\S+\s+?\S*?\s+(\d+)\s') {LOGOFF $Matches[1]}
            }
            for ($j = 6; $j; $j--) {
                Start-Sleep -Seconds 5
                if (-not (QUERY USER 2> $null)) {break outer}
            }
        }
        if (-not $i) {
            Write-Error -Message 'Timed out waiting for all User Sessions to log off.'
            exit 1
        }

        # Reset DataBase.
        $svcNames | ForEach-Object -Process {
            Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue
        }
        takeown.exe /F $dbSrc /A 1> $null
        icacls.exe $dbSrc /grant 'Administrators:(F)' 1> $null
        Remove-Item -Path "${dbSrc}*" -Force
        $svcNames | ForEach-Object -Process {
            Start-Service -Name $_ -ErrorAction SilentlyContinue
        }

        # Re-register Provisioned Applications.
        $cpuArch = switch ($env:PROCESSOR_ARCHITECTURE) {
            'AMD64' {'x64'}
            'ARM64' {'arm64'}
            'x86'   {'x86'}
            default {
                throw "Unsupported CPU architecture: ${env:PROCESSOR_ARCHITECTURE}"
            }
        }

        :nextPkg foreach ($provPkg in Get-AppxProvisionedPackage -Online) {
            $pkgMnfst = [Environment]::ExpandEnvironmentVariables(
                $provPkg.InstallLocation
            )
            [xml]$xml = Get-Content -Path $pkgMnfst -Raw
            switch ($xml.DocumentElement.LocalName) {
                'Package' {
                    $appVer      =  $xml.Package.Identity.Version
                    $appMnfst    =  $pkgMnfst
                }
                'Bundle' {
                    $appPkgs = @(
                        $xml.SelectNodes("//*[local-name()='Package']") |
                        Where-Object -FilterScript {
                            ($_.Type -eq 'application') -and
                            ($_.Architecture -eq $cpuArch) -and
                            ($_.IsStub -ne 'true')
                        }
                    )
                    if ($appPkgs.Count -eq 0) {
                        Write-Warning `
                            -Message "No ${cpuArch} Application Package in $(
                                $provPkg.DisplayName
                            )."
                        continue nextPkg
                    } elseif ($appPkgs.Count -gt 1) {
                        throw `
                            "Multiple ${cpuArch} Application Packages in $(
                                $provPkg.DisplayName
                            )."
                    } else {$appPkg = $appPkgs[0]}

                    $pkgs = @(
                        Get-ChildItem `
                            -Path "${env:ProgramFiles}\WindowsApps" `
                            -Directory -Force -ErrorAction SilentlyContinue |
                        Where-Object -FilterScript {
                            ($_.Name -like "$($provPkg.DisplayName)_$($appPkg.Version)_*") -and
                            ($_.Name -match "_${cpuArch}_")
                        } |
                        Where-Object -FilterScript {Test-Path -Path (
                            Join-Path -Path $_.FullName -ChildPath 'AppxManifest.xml'
                        )}
                    )

                    if ($pkgs.Count -eq 0) {
                        Write-Warning `
                            -Message "No installation Package Directory found for $(
                                $provPkg.DisplayName
                            ) $($appPkg.Version)."
                        continue nextPkg
                    } elseif ($pkgs.Count -gt 1) {
                        throw `
                            "Multiple installation Package Directories found for $(
                                $provPkg.DisplayName
                            ) $($appPkg.Version)."
                    } else {$pkg = $pkgs[0]}

                    $appVer      =  $appPkg.Version
                    $appMnfst    =  (
                        Join-Path `
                            -Path $pkg.FullName `
                            -ChildPath 'AppxManifest.xml'
                    )
                }
                default {
                    Write-Warning `
                        -Message "Unknown AppX XML root ``$(
                            $xml.DocumentElement.LocalName
                        )`` for $($provPkg.DisplayName)."
                    continue nextPkg
                }
            }

            Write-Host "Registering $($provPkg.DisplayName) ${appVer}..."
            Add-AppxPackage -Register $appMnfst -DisableDevelopmentMode
        }
    }
    ```
    </details>
  -->
  - <details><summary>Common Procedures.</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    # Disable BitLocker.
    & {
        $nl = ''
        Write-Host "[$(Get-Date -Format 'o')] Disabling BitLocker..."
        while ($vStat = [int](
            Get-BitLockerVolume `
                -MountPoint $env:SystemDrive `
                -ErrorAction SilentlyContinue
        ).VolumeStatus) {
            if ($vStat -ne 3) {
                Disable-BitLocker -MountPoint $env:SystemDrive
            }
            Write-Host "`r[$(Get-Date -Format 'o')] Decrypting: $((
                Get-BitLockerVolume -MountPoint $env:SystemDrive
            ).EncryptionPercentage)% ..." -NoNewline
            $nl = "`n"
            Start-Sleep -Seconds 5
        }
        Write-Host "${nl}[$(Get-Date -Format 'o')] Done."
    }

    # Clean up Application artifacts.
    & {
        $ErrorActionPreference = 'SilentlyContinue'

        # Remove AppX packages installed at User level only (not provisioned
        #   for All Users), to avoid `sysprep /generalize` failure.
        & {
            $provPkgs = @(
                Get-AppxProvisionedPackage -Online |
                Select-Object -ExpandProperty DisplayName
            )
            <#
            $lclSIDs = @(
                Get-LocalUser |
                Where-Object -FilterScript {
                    $rid = [int]($_.Sid.Value -split '-')[-1]
                    (
                        ($_.Sid.Value -like 'S-1-5-21-*') -and
                        (($rid -eq 500) -or ($rid -ge 1000))
                    )
                } |
                Select-Object -ExpandProperty SID |
                ForEach-Object -Process {$_.Value}
            )
            #>

            . {
                Get-AppxPackage -AllUsers |
                Where-Object -FilterScript {
                    $installed = @(
                        $_.PackageUserInformation |
                        Where-Object -FilterScript {
                            $_.InstallState -eq 'Installed'
                        }
                    )
                    (
                        ($installed.Count -gt 0) -and
                        ($_.Name -notin $provPkgs) -and
                        ($_.SignatureKind -ne 'System') -and
                        ($_.IsFramework -eq $false) -and
                        ($_.NonRemovable -eq $false)
                    )
                } |
                Select-Object -Property @(
                    'Name', 'Version', 'PackageFullName',
                    @{N='Users'; E={
                        $_.PackageUserInformation |
                        Where-Object -FilterScript {$_.InstallState -eq 'Installed'} |
                        ForEach-Object -Process {$_.UserSecurityId.Sid}
                    }}
                ) |
                ForEach-Object -Process {
                    Write-Host "Removing..."
                    $_ | Format-List
                    Remove-AppxPackage `
                        -Package $_.PackageFullName `
                        -AllUsers
                }
            }
        }
    }

    # Clean up Users artifacts.
    & {
        $ErrorActionPreference = 'SilentlyContinue'

        # Force logoff all User Sessions.
        :outer for ($i = 3; $i; $i--) {
            (QUERY USER 2> $null) | Select-Object -Skip 1 | ForEach-Object -Process {
                if ($_ -match '^\s*\S+\s+?\S*?\s+(\d+)\s') {LOGOFF $Matches[1]}
            }
            for ($j = 6; $j; $j--) {
                Start-Sleep -Seconds 5
                if (-not (QUERY USER 2> $null)) {break outer}
            }
        }
        if (-not $i) {
            Write-Error -Message 'Timed out waiting for all User Sessions to log off.'
            exit 1
        }

        function Remove-Contents ([string]$Path) {
            if (Test-Path -LiteralPath $Path -PathType Container) {
                Get-ChildItem -LiteralPath $Path -Force |
                Remove-Item -Recurse -Force
            }
        }

        @('qa-usr') | ForEach-Object -Process {
            $usrID = $_
            $sid = (Get-LocalUser -Name $usrID).Sid.Value
            if (-not $sid) {return}
            $usrProf = (
                Get-ItemProperty `
                    -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\${sid}" `
                    -Name ProfileImagePath
            ).ProfileImagePath
            if (-not $usrProf) {return}
            $lclData = "${usrProf}\AppData\Local"
            $usrData = "${usrProf}\AppData\Roaming"

            # Various Caches and Temporary Files.
            @(
                "${lclData}\Temp\"                                      # User TEMP.
                "${lclData}\CrashDumps\"
                "${lclData}\Diagnostics\"
                "${lclData}\Microsoft\Windows\Caches\"
                "${lclData}\Microsoft\Windows\DeliveryOptimization\"
                "${lclData}\Microsoft\Windows\Feedback\"
                "${lclData}\Microsoft\Windows\History\"
                "${usrData}\Microsoft\Windows\Recent\"
                "${lclData}\Microsoft\Windows\WER\"                     # Window Error Reporting.
                "${lclData}\Microsoft\Windows\INetCache\"               # MS Browser Cache
                "${lclData}\Microsoft\Windows\INetCookies\"             #   and Cookies.
            ) | ForEach-Object -Process {Remove-Contents $_}
            # Explorer Thumbnail/Icon Cache.
            . {
                Get-ChildItem `
                    -LiteralPath "${lclData}\Microsoft\Windows\Explorer\" `
                    -File -Force |
                Where-Object -FilterScript {
                    ($_.Name -like 'thumbcache_*.db') -or
                    ($_.Name -like 'iconcache*.db')
                } |
                Remove-Item -Force
            }
            # PowerShell Command History.
            Remove-Item -LiteralPath @(
                "${usrData}\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt",
                "${lclData}\Microsoft\PowerShell\PSReadLine\ConsoleHost_history.txt"
            ) -Force
            # Packaged Application Temporary/Cache Data.
            Get-ChildItem `
                -LiteralPath "${lclData}\Packages\" `
                -Directory -Force |
                ForEach-Object -Process {
                    Remove-Contents "$($_.FullName)\AC\Temp"
                    Remove-Contents "$($_.FullName)\LocalCache"
                }
        }
    }

    # Clean up System artifacts.
    & {
        $ErrorActionPreference = 'SilentlyContinue'

        # Various Logs and Temporary Files.
        @(
            # Clean up Panther logs.
            "${env:SystemRoot}\Panther",                    # Panther
            "${env:SystemRoot}\System32\Sysprep\Panther"    #   logs.
            "${env:SystemRoot}\SystemTemp"                  # System
            "${env:SystemRoot}\Temp"                        #   TEMP.
        ) | ForEach-Object -Process {
            if (Test-Path -Path $_ -PathType Container) {
                Get-ChildItem -Path $_ -Force |
                Remove-Item -Recurse -Force
            }
        }

        # Clear Recycle Bin.
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    }

    # Clean up QA Customization.
    & {
        $ErrorActionPreference = 'SilentlyContinue'

        # Temporary Files.
        Remove-Item `
            -Path "${env:SystemDrive}\TEMP\*" `
            -Recurse -Force
    }
    ```
    </details>
**Deployment Options:**
  - <details><summary>Standard Windows</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    # Merge all custom unattend files into a single standard Windows unattend.
    & {
        $stdXML = [xml](@'
    <?xml version="1.0" encoding="utf-8"?>
    <unattend
        xmlns="urn:schemas-microsoft-com:unattend"
        xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
    />
    '@ + "`n")
        @(
            "${env:SystemRoot}\System32\Sysprep\unattend--specialize.xml",
            "${env:SystemRoot}\System32\Sysprep\unattend--oobe.xml"
        ) | ForEach-Object -Process {
            ([xml](Get-Content -Path $_ -Raw)).unattend.settings | ForEach-Object -Process {
                $stdXML.unattend.AppendChild($stdXML.ImportNode($_, $true)) |
                Out-Null
            }
        }
        $stdXML.Save("${env:SystemRoot}\System32\Sysprep\unattend--std-win.xml")
    }

    # Generalize the system.
    ($(
        $okTag = "${env:SystemRoot}\System32\Sysprep\Sysprep_succeeded.tag"
        Remove-Item -Path $okTag -Force -ErrorAction SilentlyContinue
        ((
            Start-Process `
                -Wait -NoNewWindow -PassThru `
                -FilePath "${env:SystemRoot}\System32\Sysprep\sysprep.exe" `
                -ArgumentList @(
                    '/quiet', '/mode:vm',
                    '/generalize', '/oobe', '/quit', (
                        "`"/unattend:" +
                        "${env:SystemRoot}\System32\Sysprep\" +
                        "unattend--std-win.xml`""
                    )
                )
        ).ExitCode -eq 0) -and (Test-Path -Path $okTag)
    ) -or (
        Write-Host 'SysPrep FAIL!!!' `
            -BackgroundColor Black -ForegroundColor Red
    )) | Out-Null
    ```
    </details>
  - <details><summary>Using CloudBase-Init</summary>
    <details><summary>Installation</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    # Download the installation package.
    Invoke-WebRequest `
        -Uri 'https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' `
        -OutFile "${env:SystemRoot}\Temp\CloudbaseInit.msi"

    # Install.
    Start-Process `
        -Wait -NoNewWindow `
        -FilePath 'msiexec.exe' `
        -ArgumentList @(
            '/i', "`"${env:SystemRoot}\Temp\CloudbaseInit.msi`"",
            '/qn',
            '/l*v', "`"${env:SystemRoot}\Temp\cloudbase-init-install.log`""
        )

    # Verify.
    Get-Service -Name 'cloudbase-init' |
        Select-Object -Property @('Name', 'Status', 'StartType')

    # Delete the installation package.
    Remove-Item -Path "${env:SystemRoot}\Temp\CloudbaseInit.msi"
    ```
    </details>
    <details><summary>Configuration</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    # Create CloudBase-Init RunTime Scripts.
    New-Item `
        -ItemType Directory `
        -Path "${env:ProgramData}\Scripts" `
        -Force 1> $null
    Set-Content `
        -Path "${env:ProgramData}\Scripts\Script--App--CloudBaseInit--Main.ps1" `
        -Encoding UTF8 -NoNewline `
        -Value (@'
    # Execute all Leaf scripts in sorted numeric order.
    Get-ChildItem `
        -Path "${env:ProgramData}\Scripts" `
        -Filter 'Script--App--CloudBaseInit--Leaf--*.ps1' `
        -ErrorAction SilentlyContinue |
    Where-Object -FilterScript {
        $_.BaseName -match '^Script--App--CloudBaseInit--Leaf--\d+--'
    } |
    Sort-Object -Property {
        $_.BaseName -match '^\D+--(\d+)--' 1> $null
        [int]$Matches[1]
    } |
    ForEach-Object -Process {& $_.FullName}

    # Clear `UserDataPlugin` tracking, so it runs again on next boot.
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle', 'Hidden',
        '-EncodedCommand',  ([Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes({
                while ((Get-Service -Name 'cloudbase-init').Status -eq 'Running')
                    {Start-Sleep -Seconds 1}
                Get-ChildItem `
                    -Path 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init' |
                ForEach-Object -Process {
                    Remove-ItemProperty `
                        -Path "$($_.PSPath)\Plugins" `
                        -Name UserDataPlugin `
                        -ErrorAction SilentlyContinue
                }
            }.ToString())
        ))
    )
    exit 0
    '@ + "`n")

    Set-Content `
        -Path "${env:ProgramData}\Scripts\Script--App--CloudBaseInit--Leaf--00--SSH.ps1" `
        -Encoding UTF8 -NoNewline `
        -Value (@'
    $dataFile    =  "${env:ProgramData}\Scripts\Data--App--CloudBaseInit--SSH.txt"
    $authFile    =  "${env:ProgramData}\ssh\administrators_authorized_keys"
    if (-not (Test-Path -Path $dataFile)) {return}

    $newKey      =  (Get-Content -Path $dataFile -Raw).TrimEnd()
    $keyBody     =  ($newKey -split ' ')[1]
    New-Item `
        -ItemType Directory `
        -Path (Split-Path -Path $authFile -Parent) `
        -Force 1> $null
    $lines = @($(if (Test-Path -Path $authFile) {
        Get-Content -Path $authFile |
        Where-Object -FilterScript {($_ -split ' ')[1] -ne $keyBody}
    } else {@()}))
    ($lines + $newKey) | Set-Content -Path $authFile -Encoding Ascii
    icacls.exe $authFile /reset
    icacls.exe $authFile /inheritance:r /grant:r `
        'BUILTIN\Administrators:(F)' 'NT AUTHORITY\SYSTEM:(F)'
    exit 0
    '@ + "`n")

    # Configure CloudBase-Init to use NoCloud + ConfigDrive metadata sources only.
    #   Both conf. files need updating: `cloudbase-init-unattend.conf` (specialize
    #   pass -- hostname) and `cloudbase-init.conf` (service -- SSH key injection,
    #   etc.).
    #   By default, they try HTTP metadata services (169.254.169.254) which gets
    #   stuck during specialize since networking is not yet up.
    & {
        $newKeys = [ordered]@{
            'metadata_services'  =  'metadata_services=' +
                                    'cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService,' +
                                    'cloudbaseinit.metadata.services.configdrive.ConfigDriveService'
            'username'           =  'username=Administrator'
        }
        @(
            "${env:ProgramFiles}\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf",
            "${env:ProgramFiles}\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf"
        ) | ForEach-Object -Process {
            $keys = [System.Management.Automation.PSSerializer]::Deserialize(
                [System.Management.Automation.PSSerializer]::Serialize($newKeys)
            )
            $lines = Get-Content -Path $_ | ForEach-Object -Process {
                switch -Regex ($_) {
                    ('^(' + ($newKeys.Keys -join '|') + ')=') {
                        $key = ($_ -split '=')[0]
                        if ($keys.Contains($key)) {$keys[$key]; $keys.Remove($key)}
                        break
                    }
                    default {$_}
                }
            }
            $keys.Values | ForEach-Object -Process {$lines += $_}
            [System.IO.File]::WriteAllLines($_, $lines, [System.Text.Encoding]::ASCII)
        }
    }

    ```
    </details>
    <details><summary>Workflow</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    # Merge CloudBase-Init `Unattend.xml` with custom `unattend` files (all passes).
    & {
        # Helper Functions.
        ##  Deep merge.
        function MergeXMLnode ($src, $dst, $doc) {
            $src.ChildNodes |
            Where-Object -FilterScript {$_.NodeType -eq 'Element'} |
            ForEach-Object -Process {
                if ($_.GetAttribute(
                    'action',
                    'http://schemas.microsoft.com/WMIConfig/2002/State'
                ) -eq 'add') {
                    $dst.AppendChild($doc.ImportNode($_, $true)) | Out-Null
                } else {
                    $dstEl = $dst[$_.LocalName]
                    if (-not $dstEl) {
                        $dst.AppendChild($doc.ImportNode($_, $true)) | Out-Null
                    } else {
                        MergeXMLnode $_ $dstEl $doc
                    }
                }
            }
        }

        $cbXML = [xml](
            Get-Content `
                -Path "${env:ProgramFiles}\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml" `
                -Raw
        )
        @(
            "${env:SystemRoot}\System32\Sysprep\unattend--specialize.xml",
            "${env:SystemRoot}\System32\Sysprep\unattend--oobe.xml"
        ) | ForEach-Object -Process {
            ([xml](Get-Content -Path $_ -Raw)).unattend.settings | ForEach-Object -Process {
                $srcPass = $_
                $dstPass = $cbXML.unattend.settings | Where-Object -FilterScript {$_.pass -eq $srcPass.pass}
                if (-not $dstPass) {
                    $cbXML.unattend.AppendChild($cbXML.ImportNode($srcPass, $true)) |
                    Out-Null
                } else {
                    $srcPass.component | ForEach-Object -Process {
                        $srcComp = $_
                        $dstComp = $dstPass.component | Where-Object -FilterScript {$_.name -eq $srcComp.name}
                        if (-not $dstComp) {
                            $dstPass.AppendChild($cbXML.ImportNode($srcComp, $true)) |
                            Out-Null
                        } else {
                            MergeXMLnode $srcComp $dstComp $cbXML
                        }
                    }
                }
            }
        }
        $cbXML.Save("${env:SystemRoot}\System32\Sysprep\unattend--cloudbase-init.xml")
    }

    # Clear CloudBase-Init instance state.
    Get-ChildItem `
        -Path 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init' `
        -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # Generalize the system.
    ($(
        $okTag = "${env:SystemRoot}\System32\Sysprep\Sysprep_succeeded.tag"
        Remove-Item -Path $okTag -Force -ErrorAction SilentlyContinue
        ((
            Start-Process `
                -Wait -NoNewWindow -PassThru `
                -FilePath "${env:SystemRoot}\System32\Sysprep\sysprep.exe" `
                -ArgumentList @(
                    '/quiet', '/mode:vm',
                    '/generalize', '/oobe', '/quit', (
                        "`"/unattend:" +
                        "${env:SystemRoot}\System32\Sysprep\" +
                        "unattend--cloudbase-init.xml`""
                    )
                )
        ).ExitCode -eq 0) -and (Test-Path -Path $okTag)
    ) -or (
        Write-Host 'SysPrep FAIL!!!' `
            -BackgroundColor Black -ForegroundColor Red
    )) | Out-Null
    ```
    </details>
    </details>
**Post-Actions:**
  - <details><summary>Optional: Minimize Image Size</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    # Disable BitLocker (the `sysprep /generalize` re-enabled it).
    & {
        $nl = ''
        Write-Host "[$(Get-Date -Format 'o')] Disabling BitLocker..."
        while ($vStat = [int](
            Get-BitLockerVolume `
                -MountPoint $env:SystemDrive `
                -ErrorAction SilentlyContinue
        ).VolumeStatus) {
            if ($vStat -ne 3) {
                Disable-BitLocker -MountPoint $env:SystemDrive
            }
            Write-Host "`r[$(Get-Date -Format 'o')] Decrypting: $((
                Get-BitLockerVolume -MountPoint $env:SystemDrive
            ).EncryptionPercentage)% ..." -NoNewline
            $nl = "`n"
            Start-Sleep -Seconds 5
        }
        Write-Host "${nl}[$(Get-Date -Format 'o')] Done."
    }

    # Consolidate free space.
    Defrag.exe $env:SystemDrive /X /U /V
    #   & { # Error: 0x40004 (most likely from `ReTrim` operation).
    #       $ProgressPreference = 'SilentlyContinue'
    #       Optimize-Volume `
    #           -DriveLetter $env:SystemDrive.TrimEnd(':') `
    #           -Defrag `
    #           -SlabConsolidate `
    #           -ReTrim `
    #           -Verbose
    #   }

    # Zeroing free space.
    & {
        $zFile   =  "${env:SystemDrive}\zerofile.tmp"
        $blkSz   =  64KB    # Align with NTFS and QCOW2 Cluster.
        $zStrm   =  [System.IO.File]::Create(
                        $zFile,
                        $blkSz,
                        [System.IO.FileOptions]::WriteThrough
                    )
        $zBuff   =  New-Object Byte[] (128 * $blkSz)    # 8 MiB.
        $gBdone  =  0
        $blkRem  =  0

        Write-Host "[$(Get-Date -Format 'o')] Zeroing free space..."
        try {
            while (++$gBdone) {
                $blkRem = 128
                while ($blkRem--) {$zStrm.Write($zBuff, 0, $zBuff.Length)}
                Write-Host "`r[$(
                    Get-Date -Format 'o'
                )] Written: ${gBdone} GB ..." -NoNewline
            }
        } catch {
            $zBuff   =  New-Object Byte[] ($blkSz)
            $64kBlk  =  0
            $64kInfo =  ''
            try {while ($true) {
                $zStrm.Write($zBuff, 0, $zBuff.Length)}
                $64kBlk++
            } catch{}
            if ($64kBlk) {$64kInfo += (
                "`n[$(Get-Date -Format 'o')] Written ${64kBlk} 64k-Blocks."
            )}
            Write-Host $64kInfo
        } finally {
            Write-Host "[$(Get-Date -Format 'o')] Flushing to Disk..."
            $zStrm.Flush($true)
            Write-Host "[$(Get-Date -Format 'o')] Done."
            $zStrm.Close()
            $zStrm.Dispose()
            if (Test-Path -Path $zFile) {Remove-Item -Path $zFile -Force}
        }
    }
    ```
    </details>
  - <details><summary>Finalize</summary>

    Run in PowerShell as `Administrator`:
    ```powershell
    <#  DISABLED: Breaks AppX deployment.
    # Reset AppX State Repository.
    & {
        $svcNames    =  @('StateRepository', 'AppXSvc', 'ClipSVC', 'InstallService')
        $dbSrc       =  "${env:ProgramData}\Microsoft\Windows\AppRepository\StateRepository-Machine.srd"

        # Force logoff all User Sessions.
        :outer for ($i = 3; $i; $i--) {
            (QUERY USER 2> $null) | Select-Object -Skip 1 | ForEach-Object -Process {
                if ($_ -match '^\s*\S+\s+?\S*?\s+(\d+)\s') {LOGOFF $Matches[1]}
            }
            for ($j = 6; $j; $j--) {
                Start-Sleep -Seconds 5
                if (-not (QUERY USER 2> $null)) {break outer}
            }
        }
        if (-not $i) {
            Write-Error -Message 'Timed out waiting for all User Sessions to log off.'
            exit 1
        }

        # Reset DataBase.
        $svcNames | ForEach-Object -Process {
            Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue
        }
        takeown.exe /F $dbSrc /A 1> $null
        icacls.exe $dbSrc /grant 'Administrators:(F)' 1> $null
        Remove-Item -Path "${dbSrc}*" -Force
    }
    #>

    # Clean up SysPrep.
    Remove-Item `
        -Path @(
            "${env:SystemRoot}\System32\Sysprep\unattend--*.xml",
            "${env:SystemRoot}\System32\Sysprep\unattend--*.log",
            "${env:SystemRoot}\System32\Sysprep\Sysprep_succeeded.tag",
            "${env:SystemRoot}\Panther\unattend--*.log"
        ) `
        -Force -ErrorAction SilentlyContinue

    # Remove SSH Host and `Administrator` Keys.
    Remove-Item -Path @(
        "${env:ProgramData}\ssh\administrators_authorized_keys",
        "${env:ProgramData}\ssh\ssh_host_*",
        "${env:USERPROFILE}\.ssh"
    ) -Recurse -Force -ErrorAction SilentlyContinue

    # Clear `Administrator` files.
    Remove-Item -Path @(
        "${env:TMP}\*",
        "${env:TEMP}\*",
        (Get-PSReadLineOption).HistorySavePath
    ) -Recurse -Force -ErrorAction SilentlyContinue

    # Shut down the System.
    shutdown /s /t 0
    ```
    </details>
</details>
</details>
</details>
</details>
<details><summary>Exporting VM Disk Image to VM Image Template</summary>

```shell
_VIRT__NS='...ns...' \
_VIRT__NS='ieng--vm-img' \
    _VIRT__VM__NAME='...vmName...' \
    _VIRT__VM__NAME='vm-img--windows' \
    _VIRT__VM__DISK_NAME='...vmVHDname...' \
    _VIRT__VM__DISK_NAME='vhd--00-fs-rootfs' \
    _VIRT__VM__ARCH='...cpuArch...' \
    _VIRT__VM__ARCH='amd64' \
    _VIRT__VM__ARCH='arm64' \
    _VIRT__DIT__DISK_SIZE='...diskImgToolVHDsize...' \
    _VIRT__DIT__DISK_SIZE='256Gi' \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        typeset vmDskImgVer="$(date '+%Y%m%dt%H%M')"

        trap '
            : Cleaning up. Do NOT press another \`Ctrl+C\`!!!
            oc -n "${_VIRT__NS}" delete Pod/disk-img-tool --ignore-not-found
        ' EXIT

        # Create Disk Image Tool Pod.
        ##  Create PVC for R/W storage.
        {
            oc create -f - --dry-run=client -o json --save-config |
            jq -c \
                --arg vmNS "${_VIRT__NS}" \
                --arg ditDiskSize "${_VIRT__DIT__DISK_SIZE}" \
                '
                    .metadata.namespace=$vmNS |
                    .spec.resources.requests.storage=$ditDiskSize
                ' |
            yq -p json -o yaml eval .
        } 0<<'ocEOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: disk-img-tool--pvc--00-ws
  namespace: ''
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ''
ocEOF
        ##  Create the Pod.
#       oc -n "${_VIRT__NS}" run disk-img-tool \
#           --image="$(
#               oc -n "${_VIRT__NS}" get Pods \
#                   -l kubevirt.io=virt-launcher \
#                   -o jsonpath='{.items[0].spec.containers[0].image}'
#           )" \
#           --restart=Never \
#           --command \
#           -- /bin/bash -c "sleep infinity"
        {
            oc create -f - --dry-run=client -o json --save-config |
            jq -c \
                --arg vmNS "${_VIRT__NS}" \
                --arg ditCtrImg "$(
                    oc -n "${_VIRT__NS}" get Pods \
                        -l kubevirt.io=virt-launcher \
                        -o jsonpath='{.items[0].spec.containers[0].image}'
                )" \
                --argjson vmEnv "$(
                    export _VIRT__VM__DISK_IMG_VER="${vmDskImgVer}"
                    jq -c '[.[] | {name: ., value: $ENV[.]}]' 0< <(
                        echo '[
                            "_VIRT__NS",
                            "_VIRT__VM__NAME",
                            "_VIRT__VM__DISK_NAME",
                            "_VIRT__VM__DISK_IMG_VER"
                        ]'
                    )
                )" \
                '
                    .metadata.namespace=$vmNS |
                    .spec.containers[0].image=$ditCtrImg |
                    .spec.containers[0].env += $vmEnv
                ' |
            yq -p json -o yaml eval .
        } 0< <(cat 0<<'ocEOF'
apiVersion: v1
kind: Pod
metadata:
  name: disk-img-tool
  namespace: ''
spec:
  containers:
    - name: disk-img-tool
      image: quay.io/kubevirt/virt-launcher:v1.2.0
      command: ['/bin/bash', '-c', 'sleep infinity']
      env:
        - name: KUBECONFIG
          value: /ws/kubeconfig
      volumeMounts:
        - name: ws
          mountPath: /ws
  volumes:
    - name: ws
      persistentVolumeClaim:
        claimName: disk-img-tool--pvc--00-ws
  restartPolicy: Never
ocEOF
        ) | oc apply -f -
        oc -n "${_VIRT__NS}" wait Pod/disk-img-tool \
            --for condition=Ready \
            --timeout 60s
        ##  Prepare the Pod.
        (
            ### Transfer required files.
            for e in oc virtctl; do
                oc -n "${_VIRT__NS}" cp \
                    "$(which "${e}")" disk-img-tool:/ws/
            done
            ##  Login to VM's OCP.
            ( set +x
                oc -n "${_VIRT__NS}" exec Pod/disk-img-tool \
                    -- /ws/oc login \
                        --token="$(oc whoami --show-token)" \
                        --server="$(oc whoami --show-server)"
            true )
        true )
        ##  Sanity check.
        oc -n "${_VIRT__NS}" exec Pod/disk-img-tool -- bash -euxc '
            qemu-img --version
            df -h /ws/
        '

        # Export the VM Disk Image.
#       oc -n "${_VIRT__NS}" exec Pod/disk-img-tool \
#           -- bash -euxc '
#               mkfifo /ws/disk.raw.fifo
#               qemu-img convert \
#                   -p -c -S 512 -f raw -o compression_type=zstd -O qcow2 \
#                   /ws/disk.raw.fifo /ws/disk.qcow2 &
#               sleep 5
#           '
        oc -n "${_VIRT__NS}" exec Pod/disk-img-tool \
            -it \
            -- bash -euxc "$(cat - 0<<'rmtEOF'
{
    /ws/virtctl -n "${_VIRT__NS}" vmexport download  \
        "vm-export--${_VIRT__VM__NAME}--${_VIRT__VM__DISK_IMG_VER}" \
        --vm "${_VIRT__VM__NAME}" \
        --volume "${_VIRT__VM__DISK_NAME}" \
        --output - |
    gunzip > /ws/disk.raw
#   gunzip > /ws/disk.raw.fifo
}
ls -laFh /ws/
true
rmtEOF
            )"
        oc -n "${_VIRT__NS}" exec Pod/disk-img-tool \
            -- bash -euxc "$(cat - 0<<'rmtEOF'  # Zeroing partition gaps.
typeset vhdFile=/ws/disk.raw
typeset diskPartInfo="$(fdisk -l "${vhdFile}")"
typeset partType="$(awk '
    /^Disklabel type/ {print $3; exit}
' 0<<< "${diskPartInfo}")"
typeset -i diskSectLim=$(awk '
    /^Disk .* bytes/ {print $(NF-1); exit}
' 0<<< "${diskPartInfo}")
typeset -i sectSize=$(awk '
    /Sector size/ {print $4; exit}
' 0<<< "${diskPartInfo}")
typeset -i i=0 lastPartEnd=0 thisPartBgn=0 blkSz=0 gapSz=0 multFact=1
typeset -a partTable=($(awk -v d="${vhdFile}[0-9]+" '
    $1 ~ "^"d {print $2","$3}
' 0<<< "${diskPartInfo}"))

# Convert to MiB.
case ${sectSize} in
  (512)     ((diskSectLim /= 2048));;
  (4096)    ((diskSectLim /= 256));;
  (*)       : "Unsupported Sector Size: ${sectSize}" 1>&2; exit 1;;
esac

# Protect GPT Backup Header.
case ${partType} in
  (gpt) ((diskSectLim--));;
  (dos) ;;
  (*)   : "Unknown Partition Type: ${partType}" 1>&2; exit 1;;
esac

# Convert back to sectors (exclusive upper bound limit).
((diskSectLim *= 1048576 / sectSize))

((${#partTable[@]})) || partTable+=("-1,-1")
partTable+=("${diskSectLim},${diskSectLim}")
lastPartEnd=${partTable[0]#*,}
for ((i=1; i < ${#partTable[@]}; i++)); do
    thisPartBgn=${partTable[i]%,*}
    if ((thisPartBgn > ++lastPartEnd)); then
        # Get the possible largest Block Size.
        ((blkSz = sectSize, gapSz = thisPartBgn - lastPartEnd))
        while (((blkSz *= 2) <= 1073741824)); do
            ((
                ((lastPartEnd % (blkSz / sectSize)) == 0) && \
                ((gapSz % (blkSz / sectSize)) == 0 )
            )) || break
        done
        ((blkSz /= 2, multFact = blkSz / sectSize))
        dd \
            if=/dev/zero of="${vhdFile}" \
            conv=notrunc bs=${blkSz} \
            seek=$((lastPartEnd / multFact)) count=$((gapSz / multFact)) \
            status=progress
    fi
    lastPartEnd=${partTable[i]#*,}
done

true
rmtEOF
            )"
        oc -n "${_VIRT__NS}" exec Pod/disk-img-tool \
            -- qemu-img convert \
                    -p -c -S 512 -f raw -o compression_type=zstd -O qcow2 \
                    /ws/disk.raw /ws/disk.qcow2
        oc -n "${_VIRT__NS}" exec Pod/disk-img-tool -- bash -euxc '
#           rm /ws/disk.raw.fifo
            ls -laFh /ws/
            qemu-img info /ws/disk.qcow2
            qemu-img check /ws/disk.qcow2
        '
        {
            oc -n "${_VIRT__NS}" exec Pod/disk-img-tool \
                -- cat /ws/disk.qcow2 |
            dd \
                of="./${_VIRT__VM__NAME}--${vmDskImgVer}--00-hdd.qcow2" bs=4M \
                status=progress
        }
#       oc -n "${_VIRT__NS}" cp \
#           disk-img-tool:/ws/disk.qcow2 \
#           "./${_VIRT__VM__NAME}--${vmDskImgVer}--00-hdd.qcow2"

        # Cleaning up Disk Image Tool Pod.
        oc -n "${_VIRT__NS}" delete \
            Pod/disk-img-tool \
            --ignore-not-found
        oc -n "${_VIRT__NS}" delete \
            PersistentVolumeClaim/disk-img-tool--pvc--00-ws \
            --ignore-not-found

        ls -laFh "./${_VIRT__VM__NAME}--${vmDskImgVer}--00-hdd.qcow2"

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Uploading VM Disk Image to Container Registry</summary>

```shell
_VIRT__VM__NAME='...vmName...' \
    _VIRT__VM__NAME='ieng--windows--master' \
    _VIRT__VM__DISK_IMG__REPO_PATH='images.paas.redhat.com/ieng/vm-img--rhov' \
    _VIRT__VM__DISK_IMG_VER='...vmDskImgVer...' \
    _VIRT__VM__OS_VER='win11' \
    _VIRT__VM__ARCH='...cpuArch...' \
    _VIRT__VM__ARCH='arm64' \
    _VIRT__VM__ARCH='amd64' \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'

        # Creating Containerized Disk Image.
        podman image build \
            -f - \
            --platform "linux/${_VIRT__VM__ARCH}" \
            -t "${_VIRT__VM__DISK_IMG__REPO_PATH}/${_VIRT__VM__NAME}:${_VIRT__VM__OS_VER:+${_VIRT__VM__OS_VER}-}${_VIRT__VM__ARCH}-latest" \
            -t "${_VIRT__VM__DISK_IMG__REPO_PATH}/${_VIRT__VM__NAME}:${_VIRT__VM__OS_VER:+${_VIRT__VM__OS_VER}-}${_VIRT__VM__ARCH}-${_VIRT__VM__DISK_IMG_VER}" \
            . 0<<bldEOF
FROM scratch
# Assuming `uid`/`gid` 107 is `qemu`.
ADD --chown=107:107 --chmod=0440 [$(
    jq -cn \
        --arg vmName "${_VIRT__VM__NAME}" \
        --arg vmDskImgVer "${_VIRT__VM__DISK_IMG_VER}" \
        '"./\($vmName)--\($vmDskImgVer)--00-hdd.qcow2"'
), "/disk/disk.img"]
bldEOF
        (
            for e in "${_VIRT__VM__ARCH}-"{latest,"${_VIRT__VM__DISK_IMG_VER}"}; do
                podman image push \
                    "${_VIRT__VM__DISK_IMG__REPO_PATH}/${_VIRT__VM__NAME}:${_VIRT__VM__OS_VER:+${_VIRT__VM__OS_VER}-}${e}"
            done
        true )
        podman pull \
            "${_VIRT__VM__DISK_IMG__REPO_PATH}/${_VIRT__VM__NAME}:${_VIRT__VM__OS_VER:+${_VIRT__VM__OS_VER}-}latest" \
            2> /dev/null || true
        podman manifest create \
            --amend \
            "${_VIRT__VM__DISK_IMG__REPO_PATH}/${_VIRT__VM__NAME}:${_VIRT__VM__OS_VER:+${_VIRT__VM__OS_VER}-}latest" \
            "${_VIRT__VM__DISK_IMG__REPO_PATH}/${_VIRT__VM__NAME}:${_VIRT__VM__OS_VER:+${_VIRT__VM__OS_VER}-}${_VIRT__VM__ARCH}-latest"
        podman manifest inspect "${_VIRT__VM__DISK_IMG__REPO_PATH}/${_VIRT__VM__NAME}:${_VIRT__VM__OS_VER:+${_VIRT__VM__OS_VER}-}latest"
        podman manifest push \
            "${_VIRT__VM__DISK_IMG__REPO_PATH}/${_VIRT__VM__NAME}:${_VIRT__VM__OS_VER:+${_VIRT__VM__OS_VER}-}latest" \
            "${_VIRT__VM__DISK_IMG__REPO_PATH}/${_VIRT__VM__NAME}:${_VIRT__VM__OS_VER:+${_VIRT__VM__OS_VER}-}${_VIRT__VM__DISK_IMG_VER}"
        podman manifest push \
            --rm \
            "${_VIRT__VM__DISK_IMG__REPO_PATH}/${_VIRT__VM__NAME}:${_VIRT__VM__OS_VER:+${_VIRT__VM__OS_VER}-}latest"
        {
            podman image ls -q --filter reference=\
"${_VIRT__VM__DISK_IMG__REPO_PATH}/${_VIRT__VM__NAME}" |
            xargs -r podman image rm -f
        }

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Destroying Disk Image Template Generator VM</summary>

See [Operational Tasks | Stop VM](#operational-tasks--StopVM).
</details>



## Operations
### Must Gather
<details><summary>Must Gather</summary>

```shell
oc adm must-gather --image=registry.redhat.io/container-native-virtualization/cnv-must-gather-rhel9:v4.18 -- /usr/bin/gather
```
</details>

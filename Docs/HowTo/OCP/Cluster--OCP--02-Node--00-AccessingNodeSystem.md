# Cluster -- OpenShift -- Node -- Accessing Node System
## Libraries
### Select Nodes
<details><summary>OCP</summary>

```shell
function _ocp--prim--GetNodes () {
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
            oc get Nodes --no-headers ${nodeSelector} | awk '{print \$1 "\\t" \$3}' | sort -k 1,1 -t \$'\\t'
        } | column -ts \$'\\t' ${fltCmd} | sed -E 's/\\s+\\S+\$//'
cmdEOF
    )"

    return 0
}
```
</details>



## Functions
### Shell Access
<details><summary>OCP</summary>

```shell
function ocp--prim--node--con () {
    typeset -a nodeIDs="${1:-$(_ocp--prim--GetNodes)}"; (($#)) && shift;
    typeset ocDbgOpts="${1:-${K8S__OC__DBG_OPTS:-()}}"; (($#)) && shift

    typeset e= tty=
    typeset -a ocDbgOpts="${ocDbgOpts}"

    IFS=$'\n' read -d '' -ra nodeIDs 0<<<"${nodeIDs[0]}"

    (($#)) && {
        { (($# == 1)) && [ -z "${1}" ]; } &&
            { set -- chroot /host/; tty=-t; } ||
            set -- chroot /host/ "$@"
    } || { set -- /bin/sh -c 'chroot /host/ "${SHELL}" -l'; tty=-t; }

    for e in "${nodeIDs[@]}"; do
        eval "oc debug Node/${e@Q} ${tty} ${ocDbgOpts[@]@Q} -- ${@@Q}"
    done

    return 0
}
```
</details>


### File Transfer
<details><summary>OCP (Machine Config Operator)</summary>

```shell
function ocp--MachineConfig--storage.files--get () {
    typeset obj="${1}"; (($#)) && shift
    typeset path="${1}"; (($#)) && shift

    oc get "MachineConfig/${obj}" -o yaml |
        _YQ_P="${path}" yq -r '
            .spec.config.storage.files[] |
            select(.path == env(_YQ_P)) |
            .contents.source
        ' |
        __decode--dataURL

    return 0
}

function ocp--MachineConfig--storage.files--set () {
    typeset obj="${1}"; (($#)) && shift
    typeset path="${1}"; (($#)) && shift
    typeset inFile="${1}"; (($#)) && shift

    typeset content="$(cat "${inFile}" | __encode--dataURL)"

    oc get "MachineConfig/${obj}" -o yaml |
        _YQ_P="${path}" _YQ_C="${content}" yq -r '
            (
                .spec.config.storage.files[] |
                select(.path == env(_YQ_P))
            ).contents.source=env(_YQ_C) |
            .metadata={"name": .metadata.name, "labels": .metadata.labels}
        '

    return 0
}
```
</details>

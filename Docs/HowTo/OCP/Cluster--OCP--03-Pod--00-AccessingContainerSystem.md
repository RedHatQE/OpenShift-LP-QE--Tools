# Cluster -- OpenShift -- Pod -- Accessing Container System
## Libraries
### Select Resources
<details><summary>Pod</summary>

```shell
function _ocp--prim--GetPod () {
    typeset nsID="${1:-$(_ocp--prim--GetPrj)}"; (($#)) && shift;
    typeset resID="${1}"; (($#)) && shift;

    typeset resType=Pod
    typeset lblSels= podID= ctrID=
    typeset fltCmd='| fzf --header "Select a Pod."'

    [[ "${resID}" == */* ]] && resType="${resID%%/*}"
    resType="$(oc explain "${resType}" | sed -nE 's/^KIND:\s+//p;T;q')"
    resID="${resID#*/}"
    [ "${resType}" = Pod ] && {
        podID="${resID}"
    } || {
        [ -z "${resID}" ] && resID="$(eval "
            oc ${nsID:+-n ${nsID@Q}} get ${resType@Q} \
                -o jsonpath='{range .items[*]}{.metadata.name}{\"\\n\"}{end}' \
                --sort-by '{.metadata.name}' | fzf --header 'Select a ${resType}.'
        ")"
        lblSels="$(eval "
            oc ${nsID:+-n ${nsID@Q}} get ${resType@Q}/${resID@Q} \
                -o go-template='"'
                    {{- range $k,$v := .spec.selector.matchlblSels -}}
                        {{$k}}={{$v}},
                    {{- end -}}
                '"' | sed 's/,\$//'
        ")" || return 1
    }
    [ -z "${podID}" ] && podID="$(eval "
        oc ${nsID:+-n ${nsID@Q}} get Pods \
            --field-selector status.phase=Running -l ${lblSels@Q} \
            -o jsonpath='{range .items[*]}{.metadata.name}{\"\\n\"}{end}' \
            --sort-by '{.metadata.name}'
    ")"
    [[ "${podID}" == *$'\n'* ]] || fltCmd=
    eval "echo ${podID@Q} ${fltCmd}"

    return 0
}
```
</details>
<details><summary>Container</summary>

```shell
function _ocp--prim--GetCtr () {
    typeset nsID="${1:-$(_ocp--prim--GetPrj)}"; (($#)) && shift;
    typeset podID="${1:-$(_ocp--prim--GetPod "${nsID}")}"; (($#)) && shift;

    typeset ctrID=
    typeset fltCmd='| fzf --header "Select a Container."'

    ctrID="$(
        [ -z "${podID}" ] && {
            echo 'Can NOT find any running Pod.' 1>&2
            exit 1
        }
        eval "
            oc ${nsID:+-n ${nsID@Q}} get Pod/${podID@Q} \
                -o go-template='"'
                    {{- range $index,$container := .spec.containers -}}
                        {{$index}}:{{$container.name}}{{"\n"}}
                    {{- end -}}
                '"'
        "
    )" || return 1

    [[ "${ctrID}" == *$'\n'* ]] || fltCmd=
    eval "echo ${ctrID@Q} ${fltCmd} | sed -E 's/^[^:]+://'"

    return 0
}
```
</details>



## Functions
### Console Attachment
<details><summary>OCP</summary>

Requires [_ocp--prim--GetPrj()](./Cluster--OCP--01-Cluster#SelectResources).
```shell
function ocp--prim--pod--att () {
    typeset nsID="${1:-$(_ocp--prim--GetPrj)}"; (($#)) && shift;
    typeset podID="${1:-$(_ocp--prim--GetPod "${nsID}")}"; (($#)) && shift;
    typeset ctrID="${1:-$(_ocp--prim--GetCtr "${nsID}" ${podID})}"; (($#)) && shift;
    typeset ocExecOpts="${1:-${K8S__OC__EXEC_OPTS:-()}}"; (($#)) && shift

    typeset -a ocExecOpts="${ocExecOpts}"

    eval "
        oc -n ${nsID@Q} \
            attach Pod/${podID@Q} -c ${ctrID@Q} -it ${ocExecOpts[@]@Q}
    "

    return 0
}
```
</details>


### Shell Access
<details><summary>OCP</summary>

Requires [_ocp--prim--GetPrj()](./Cluster--OCP--01-Cluster#SelectResources).
```shell
function ocp--prim--pod--con () {
    typeset nsID="${1:-$(_ocp--prim--GetPrj)}"; (($#)) && shift;
    typeset podID="${1:-$(_ocp--prim--GetPod "${nsID}")}"; (($#)) && shift;
    typeset ctrID="${1:-$(_ocp--prim--GetCtr "${nsID}" ${podID})}"; (($#)) && shift;
    typeset ocExecOpts="${1:-${K8S__OC__EXEC_OPTS:-()}}"; (($#)) && shift

    typeset tty=
    typeset -a ocExecOpts="${ocExecOpts}"

    (($#)) && {
        { (($# == 1)) && [ -z "${1}" ]; } && { set -- /bin/sh; tty=-it; } || :
    } || { set -- /bin/sh -c '"${SHELL}" -l'; tty=-it; }

    eval "
        oc -n ${nsID@Q} \
            exec Pod/${podID@Q} -c ${ctrID@Q} ${tty} ${ocExecOpts[@]@Q} -- ${@@Q}
    "

    return 0
}
```
</details>


### Debug Pod
<details><summary>OCP</summary>

```shell
function ocp--prim--pod--dbg () {
    typeset nsID="${1:-$(_ocp--prim--GetPrj)}"; (($#)) && shift;
    typeset podID="${1:-$(_ocp--prim--GetPod "${nsID}")}"; (($#)) && shift;
    typeset ctrID="${1:-$(_ocp--prim--GetCtr "${nsID}" ${podID})}"; (($#)) && shift;
    typeset ocDbgOpts="${1:-${K8S__OC__DBG_OPTS:-()}}"; (($#)) && shift

    typeset tty=
    typeset -a ocDbgOpts="${ocDbgOpts}"

    (($#)) && {
        { (($# == 1)) && [ -z "${1}" ]; } && { shift; tty=-t; } || :
    } || { set -- /bin/sh -c '"${SHELL}" -l'; tty=-t; }

    eval "
        oc -n ${nsID@Q} \
            debug Pod/${podID@Q} -c ${ctrID@Q} ${tty} ${ocDbgOpts[@]@Q} -- ${@@Q}
    "

    return 0
}
```
</details>

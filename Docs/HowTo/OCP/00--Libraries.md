# Libraries
## Generic
<details><summary>Get Relative Path from A Directory</summary>

```shell
function __RelPhyPath () {
    typeset src="${1%%+(/)}"; (($#)) && shift
    typeset tgt="${1%%+(/)}"; (($#)) && shift

    typeset rPath=
    typeset -i i=0 j=0
    typeset -a sPaths=() tPaths=()

    IFS=/ read -d '' -ra sPaths 0< <(printf '%s\0' "$(
        CDPATH= \command cd -L "${src}/" 2> /dev/null || exit
        \command pwd -P
    )")
    ((${#sPaths[@]})) || {
        echo "The path \`${src}\` does NOT exist." 1>&2
        return 1
    }
    IFS=/ read -d '' -ra tPaths 0< <(printf '%s\0' "$(
        CDPATH= \command cd -L "${tgt}/" 2> /dev/null || exit
        \command pwd -P
    )")
    ((${#tPaths[@]})) || {
        echo "The path \`${tgt}\` does NOT exist." 1>&2
        return 1
    }

    while (((i < ${#sPaths[@]}) && (i < ${#tPaths[@]}))); do
        [ "${sPaths[${i}]}" = "${tPaths[${i}]}" ] || break
        ((++i))
    done
    j=$((${#sPaths[@]} - i))
    while ((j--)); do rPath+='../'; done
    rPath+="$(IFS=/; echo "${tPaths[*]:i}")"

    echo "${rPath}"
    return 0
}
```
</details>
<details><summary>Find Free TCP Port</summary>

```shell
function __RandomFreePort () {
    typeset -i min="${1}"; (($#)) && shift
    typeset -i max="${1}"; (($#)) && shift

    typeset -i tot=$((max - min + 1)) port=0

    while read -r port; do
        ((port)) && nc -zw 1 localhost ${port} 2> /dev/null || break
    done 0< <(shuf -i ${min}-${max} -n ${tot}; echo 0)

    echo ${port}
    return 0
}
```
</details>
<details><summary>Validate Local & Remote TCP Port for Port Fowarding</summary>

```shell
function __ValidatePortFwds () {
    typeset -i lPort="${1}"; (($#)) && shift
    typeset -i lTot="${1}"; (($#)) && shift
    typeset -i rPort="${1}"; (($#)) && shift

    typeset -i i=0 j=0

    (((rPort < 1) || (rPort > 65535))) && (cat - 0<<'errEOF' 1>&2
TCP Port no. MUST be between 1 - 65535!!!
Please use a valid Remote Port.
errEOF
    ) && return 1
    i=${lTot} j=${lPort}
    (((j < 1) || ((j + i) > 65536))) && (cat - 0<<errEOF 1>&2
TCP Port no. MUST be between 1 - 65535!!!
Please use different Local Port starting range that allow ${lTot}
consecutive Ports to be within valid range.
errEOF
    ) && return 1
    while ((i--)); do
        nc -zw 1 localhost $((j++)) 2> /dev/null && (cat - 0<<errEOF 1>&2
The TCP Ports ${lPort} - $((lPort + lTot- 1)) are NOT free, at least
Port no. $((j - 1)) is busy.
Please use different starting range that has free ${lTot} consecutive Ports.
errEOF
        ) && return 1
    done

    return 0
}
```
</details>

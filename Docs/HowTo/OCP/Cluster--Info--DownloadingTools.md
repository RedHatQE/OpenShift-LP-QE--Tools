# Cluster -- Info -- Downloading Tools
## CLIs
<details><summary>Download Basic CLI Tools</summary>

```shell
# Warning!!! This code snippet requires `yq`.
KUBECONFIG='...pathToKubeConfigFile...' \
    binDir='./' \
    bash -uc "$(cat - 0<<'cmdEOF'
        typeset apiURL= baseURL= e=
        typeset -i i=0
        typeset -a dlBaseURLs=() arr=()

        while ((--i)); do
            case ${i} in
              (2)
                e="$(oc whoami --show-console)" || continue
                baseURL="$(echo "${e}" | sed -E 's|^[^:]+://[^.]+\.apps\.([^:]+)(:[[:digit:]]+)?$|\1|')"
                ;;&
              (1)
                apiURL="$(yq -e '.clusters[].cluster.server' "${KUBECONFIG}" | sed -n '1p')"
                [ -z "${apiURL}" ] && read -p 'Enter the Cluster API URL: ' apiURL
                [ -z "${apiURL}" ] && exit
                e="${apiURL}"
                baseURL="$(echo "${e}" | sed -E 's|^[^:]+://api\.([^:]+)(:[[:digit:]]+)?$|\1|')"
                ;;&
              (*)
                schemaURL="$(echo "${e}" | sed -E 's|:.*$||')"
                for e in "${dlBaseURLs[@]}"; do
                    [ "${e}" = "${schemaURL}|${baseURL}" ] && continue 2
                done
                dlBaseURLs+=("${schemaURL}|${baseURL}")
                ;;
            esac
        done

        for e in "${dlBaseURLs}"; do
            schemaURL="${e%%|*}"; baseURL="${e##*|}"
            typeset -a toolArr=(
                "(  ''  'oc'                '${schemaURL}://downloads-openshift-console.apps.${baseURL}/amd64/linux/oc.tar'                                 )"
                "(  z   'tkn tkn-pac opc'   '${schemaURL}://tkn-cli-serve-openshift-pipelines.apps.${baseURL}/tkn/tkn-linux-amd64.tar.gz'                   )"
                "(  z   'virtctl'           '${schemaURL}://hyperconverged-cluster-cli-download-openshift-cnv.apps.${baseURL}/amd64/linux/virtctl.tar.gz'   )"
            )
            for e in "${toolArr[@]}"; do
                eval "arr=${e}"
                eval "e=(${arr[1]})"
                arr+=("${e[0]}")
                curl -kfsSLI "${arr[2]}" 1> /dev/null 2>&1 &&
                curl -kfssL "${arr[2]}" | tar "${arr[0]}vx" -C "${binDir}" "${e[@]}"
                case ${arr[3]} in
                  (oc)  [ -e "${binDir}/oc" ] && ln -sf oc "${binDir}/kubectl";;
                esac
            done
        done

        true
cmdEOF
    )"
```
</details>
<details><summary>Download Cloud Credential Operator Utility CLI</summary>

```shell
function ocp--get-cli--ccoctl () {
    typeset binDir="${1:-${K8S__CLUSTER_DIR}/bin}"; (($#)) && shift

    typeset ns='openshift-cloud-credential-operator'

    typeset podName="$(
        oc -n "${ns}" get Pods \
            -o jsonpath=\
'{.items[?(@.status.phase=="Running")].metadata.name}' \
            -l app=cloud-credential-operator
    )"

    [ -z "${podName}" ] &&
        echo 'Cloud Credential Operator is NOT running.' || {
            oc cp \
                "${ns}/${podName}:/usr/bin/ccoctl" "${binDir}/ccoctl" \
                -c cloud-credential-operator 1> /dev/null
            chmod a+x "${binDir}/ccoctl"
        }

    return 0
}
```
</details>

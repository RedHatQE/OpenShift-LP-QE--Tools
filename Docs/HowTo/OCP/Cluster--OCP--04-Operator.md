# Cluster -- OpenShift -- Operator
## References
<details><summary>Installation</summary>

[Operator Installation Procedure](https://github.com/openshift/release/blob/master/ci-operator/step-registry/install-operators/install-operators-commands.sh)
</details>


## Operations
### Installation
<details><summary>Installing Operator</summary>

Requires [ocp--crd--operator--00-core--mco--monitor-mcp-roll-out()](./Cluster--OCP--04-Operator-00-CoreOperator--MCO.md#Monitoring).
```shell
: ocp--crd--operator--install "$({ yq -o json e . | jq -c .; } 0<<'argEOF'
namespace: open-cluster-management
name: advanced-cluster-management
#version: advanced-cluster-management.v.2.12.0  # Comment out or set to `null` or empty string to get latest version.
#catalogImage: quay.io/rhceph-dev/ocs-registry:latest-stable-4.20   # Comment out or set to `null` or empty string to skip the import.
source: redhat-operators
channel: '!default'
operatorGroup: open-cluster-management--group
targetNamespaces: '!install'
monitor: false
#config:
argEOF
)"
#   ocp--crd--operator--install '{"namespace":"open-cluster-management","name":"advanced-cluster-management","source":"redhat-operators","channel":"!default","operatorGroup":"open-cluster-management--group","targetNamespaces":"!install","monitor":false}'
function ocp--crd--operator--install () {(
    set -euo pipefail; shopt -s inherit_errexit
    typeset opInJSON="${1:-{\}}"; (($#)) && shift
    typeset -i mcWaitMCProTimeS="${1:-900}"; (($#)) && shift

    # All var. name with `__*` prefix are in JSON syntax.
    typeset __opNS= __opName= __opVer= __opImg=
    typeset __opSrc= __opChan= __opGrp= __opTgtNS=
    typeset __opMon= __opCfg=
    typeset opCSV=
    typeset e1=
    typeset -i wInt=0 wMax=0
    typeset -A opCat_imgMap=()

    IFS=$'\n' read -rd '' \
        __opNS __opName  __opVer __opImg __opSrc __opChan __opGrp __opTgtNS \
        __opMon __opCfg \
        0< <(jq -c '
            (.namespace // "openshift-operators"), (.name // ""),
            (.version // ""), (.catalogImage // ""),
            (.source // "redhat-operators"), (.channel // "!default"),
            (.operatorGroup // ""), (.targetNamespaces // ""),
            (.monitor // false), (.config // "")
        ' 0<<<"${opInJSON}") || true
    typeset -p ${!__op*} 1>&2
    [ "${__opName}" = '""' ] &&
        { echo "Operator's Name is NOT defined." 1>&2; return 1; }
    jq -en --argjson opMon "${__opMon}" \
        '($opMon | type) != "boolean"' &> /dev/null &&
        { echo 'Parameter `monitor` MUST be `boolean`.' 1>&2; return 1; }
    [ "${__opSrc}" = '"!any"' ] && {
        __opSrc="$(jq -cn --arg v "$(
            oc get "PackageManifest/${__opName:1:-1}" \
                -o jsonpath='{.status.catalogSource}'
        )" '$v')"
        [ "${__opSrc}" = '""' ] && {
            echo "The PackageManifest \`${__opName:1:-1}\` is"\
                'NOT found in any available Catalog.' 1>&2
            return 1
        }
    }
    [ "${__opChan}" = '"!default"' ] &&
        __opChan="$(jq -cn --arg v "$(
            oc get "PackageManifest/${__opName:1:-1}" \
                -o jsonpath='{.status.defaultChannel}'
        )" '$v')"
    [ "${__opChan}" = '""' ] &&
        { echo "Operator's Channel is NOT defined." 1>&2; return 1; }
    [ "${__opTgtNS}" = '"!install"' ] && __opTgtNS="${__opNS}"
    # Convert JSON syntax to Shell.
    for e1 in "${!__op@}"; do
        eval "typeset ${e1:2}"'="$(jq -cnr --argjson v "${!e1}" "\$v")"'
    done

    # Create Operator Install NameSpace.
    {
        oc create Namespace "${opNS}" \
            --dry-run=client -o json --save-config |
        jq -c \
            --argjson opMon "${__opMon}" \
            '
                if $opMon then
                    .metadata.labels += {
                        "openshift.io/cluster-monitoring": "true"
                    }
                end
            '
    } | oc apply -f -
    oc wait "Namespace/${opNS}" \
        --for jsonpath='{.status.phase}'=Active \
        --timeout 60s 1> /dev/null

    # Create Operator Group, if requested and there is none yet in the
    #   NameSpace (CSV will fail if there are more than one).
    [ -z "${opGrp}" ] || {
        (($(
            oc -n "${opNS}" get OperatorGroups -o jsonpath='{.items}' |
            jq -r 'length'
        ))) && {
            e1="$(
                oc -n "${opNS}" get OperatorGroups \
                    -o jsonpath='{.items[0].metadata.name}'
            )"
            if [ "${opGrp}" = "${e1}" ]; then
                cat - 0<<infEOF
The Operator Group \`${opGrp}\` is already exist in the NameSpace.
Ignoring \`targetNamespaces\` key from \`opInJSON\` parameter.
infEOF
            else
                cat - 0<<errEOF
There is already an Operator Group named \`$(
    oc -n "${opNS}" get OperatorGroups -o jsonpath='{.items[0].metadata.name}'
)\`
in the namespace \`${opNS}\`.
Either use that Operator Group (by removing the \`operatorGroup\` key from
\`opInJSON\` parameter OR setting it to \`null\` or empty string or the same
name) OR use a different NameSpace that do not yet have any Operator Group.
errEOF
                return 1
            fi
        }
    } || {
        {
            oc create -f - --dry-run=client -o json --save-config |
            jq -c \
                --argjson opNS "${__opNS}" \
                --argjson opGrp "${__opGrp}" \
                --argjson opTgtNS "${__opTgtNS}" \
                '
                    .metadata|=(.name=$opGrp | .namespace=$opNS) |
                    if ($opTgtNS != "") then
                        .spec.targetNamespaces=($opTgtNS | split(","))
                    end
                ' |
            yq -p json -o yaml eval .
        } 0<<'ocEOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ''
  namespace: ''
ocEOF
    }

    # Import Catalog Image for the Catalog Source, if requested.
    [ -z "${opImg}" ] || {
        # Extract Image Content Source Policy (ICSP) so the Cluster knows how to
        #   pull the image when importing Catalog Source.
        e1=/icsp.yaml
        oc image extract "${opImg}" --file "${e1}" 2> /dev/null && {
            # Import ICSP.
            e1="${e1##*/}"
            {
                {
                    oc create -f - --dry-run=client -o json --save-config
                } 0< "${e1}" | oc apply -f - | sed '/ unchanged$/q1'
            } && ocp--crd--operator--00-core--mco--monitor-mcp-roll-out \
                ${mcWaitMCProTimeS} # Monitor MCP roll out.
            rm -rf "${e1}"

        }

        # Import Catalog Source.
        {
            oc create -f - --dry-run=client -o json --save-config |
            jq -c \
                --argjson opImg "${__opImg}" \
                --argjson opSrc "${__opSrc}" \
                '
                    .metadata.name=$opSrc |
                    .spec.image=$opImg
                ' |
            yq -p json -o yaml eval .
        } 0<<'ocEOF' | oc apply -f -
kind: CatalogSource
apiVersion: operators.coreos.com/v1alpha1
metadata:
  name: ''
  namespace: openshift-marketplace
spec:
  displayName: OpenShift Container Storage
  icon:
    base64data: |
      PHN2ZyBpZD0iTGF5ZXJfMSIgZGF0YS1uYW1lPSJMYXllciAxIiB4bWxucz0iaHR0cDovL3d3
      dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxOTIgMTQ1Ij48ZGVmcz48c3R5bGU+
      LmNscy0xe2ZpbGw6I2UwMDt9PC9zdHlsZT48L2RlZnM+PHRpdGxlPlJlZEhhdC1Mb2dvLUhh
      dC1Db2xvcjwvdGl0bGU+PHBhdGggZD0iTTE1Ny43Nyw2Mi42MWExNCwxNCwwLDAsMSwuMzEs
      My40MmMwLDE0Ljg4LTE4LjEsMTcuNDYtMzAuNjEsMTcuNDZDNzguODMsODMuNDksNDIuNTMs
      NTMuMjYsNDIuNTMsNDRhNi40Myw2LjQzLDAsMCwxLC4yMi0xLjk0bC0zLjY2LDkuMDZhMTgu
      NDUsMTguNDUsMCwwLDAtMS41MSw3LjMzYzAsMTguMTEsNDEsNDUuNDgsODcuNzQsNDUuNDgs
      MjAuNjksMCwzNi40My03Ljc2LDM2LjQzLTIxLjc3LDAtMS4wOCwwLTEuOTQtMS43My0xMC4x
      M1oiLz48cGF0aCBjbGFzcz0iY2xzLTEiIGQ9Ik0xMjcuNDcsODMuNDljMTIuNTEsMCwzMC42
      MS0yLjU4LDMwLjYxLTE3LjQ2YTE0LDE0LDAsMCwwLS4zMS0zLjQybC03LjQ1LTMyLjM2Yy0x
      LjcyLTcuMTItMy4yMy0xMC4zNS0xNS43My0xNi42QzEyNC44OSw4LjY5LDEwMy43Ni41LDk3
      LjUxLjUsOTEuNjkuNSw5MCw4LDgzLjA2LDhjLTYuNjgsMC0xMS42NC01LjYtMTcuODktNS42
      LTYsMC05LjkxLDQuMDktMTIuOTMsMTIuNSwwLDAtOC40MSwyMy43Mi05LjQ5LDI3LjE2QTYu
      NDMsNi40MywwLDAsMCw0Mi41Myw0NGMwLDkuMjIsMzYuMywzOS40NSw4NC45NCwzOS40NU0x
      NjAsNzIuMDdjMS43Myw4LjE5LDEuNzMsOS4wNSwxLjczLDEwLjEzLDAsMTQtMTUuNzQsMjEu
      NzctMzYuNDMsMjEuNzdDNzguNTQsMTA0LDM3LjU4LDc2LjYsMzcuNTgsNTguNDlhMTguNDUs
      MTguNDUsMCwwLDEsMS41MS03LjMzQzIyLjI3LDUyLC41LDU1LC41LDc0LjIyYzAsMzEuNDgs
      NzQuNTksNzAuMjgsMTMzLjY1LDcwLjI4LDQ1LjI4LDAsNTYuNy0yMC40OCw1Ni43LTM2LjY1
      LDAtMTIuNzItMTEtMjcuMTYtMzAuODMtMzUuNzgiLz48L3N2Zz4=
    mediatype: image/svg+xml
  image: ''
  publisher: Red Hat
  sourceType: grpc
ocEOF

        # Monitor Catalog Source import.
        (   # Isolate `SECONDS` reset.
            # Resource Import.
            SECONDS=0 wInt=10 wMax=300      # 5 Min. Max.
            while ((SECONDS < wMax)); do
                oc -n openshift-marketplace \
                    wait "CatalogSource.operators.coreos.com/${opSrc}" \
                    --for jsonpath='{.status.connectionState.lastObservedState}=
                        READY' \
                    --timeout ${wInt}s 1> /dev/null && break
                echo "Waited ${SECONDS}/${wMax} sec.: "\
'Importing Catalog Source...' 1>&2
            done
            ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'Catalog Source import.' 1>&2; exit 2; }
            # Final status.
            oc -n openshift-marketplace \
                get "CatalogSource.operators.coreos.com/${opSrc}"
        )
    }

    # Create Subscription for the Operator.
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --argjson opNS "${__opNS}" \
            --argjson opName "${__opName}" \
            --argjson opVer "${__opVer}" \
            --argjson opSrc "${__opSrc}" \
            --argjson opChan "${__opChan}" \
            --argjson opCfg "${__opCfg}" \
            '
                .metadata|=(.name=$opName | .namespace=$opNS) |
                .spec|=(
                    .channel=$opChan | .name=$opName | .source=$opSrc |
                    if ($opVer != "") then .startingCSV=$opVer end |
                    if ($opCfg != "") then .spec.config=$opCfg end
                )
            ' |
        yq -p json -o yaml eval .
    } 0<<'ocEOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ''
  namespace: ''
spec:
  channel: ''
  installPlanApproval: Automatic
  name: ''
  source: ''
  sourceNamespace: openshift-marketplace
ocEOF

    # Monitor Operator installation.
    (   # Isolate `SECONDS` reset.
        # Subscription registration.
        SECONDS=0 wInt=10 wMax=300      # 5 Min. Max.
        while ((SECONDS < wMax)); do
            opCSV="$(
                oc -n "${opNS}" \
                    get "Subscription.operators.coreos.com/${opName}" \
                    -o jsonpath='{.status.installedCSV}'
            )"
            [ -z "${opCSV}" ] && sleep ${wInt} || break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Registering Operator Subscription...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'Operator Subscription registration.' 1>&2; exit 2; }
        # CSV installation.
        SECONDS=0 wInt=10 wMax=900      # 15 Min. Max.
        while ((SECONDS < wMax)); do
            oc -n "${opNS}" wait "ClusterServiceVersion/${opCSV}" \
                --for jsonpath='{.status.phase}'=Succeeded \
                --timeout ${wInt}s 1> /dev/null && break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Installing Operator CSV...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'Operator CSV installation.' 1>&2; exit 2; }
        # Final status.
        oc -n "${opNS}" get "ClusterServiceVersion/${opCSV}"
    )

    true
)}
```
</details>


### Removal
<details><summary>Removing Operator</summary>

Requires [ocp--crd--operator--00-core--mco--monitor-mcp-roll-out()](./Cluster--OCP--04-Operator-00-CoreOperator--MCO.md#Monitoring).
```shell
: ocp--crd--operator--remove "$({ yq -o json e . | jq -c .; } 0<<'argEOF'
namespace:
name: advanced-cluster-management
#delCatalogSource: 1
#delOperatorGroup: 0
#delNameSpace: 0
argEOF
)"
#   ocp--crd--operator--remove '{"namespace":null,"name":"advanced-cluster-management"}'
function ocp--crd--operator--remove () {(
    set -euo pipefail; shopt -s inherit_errexit
    typeset opInJSON="${1:-{\}}"; (($#)) && shift
    typeset -i mcWaitMCProTimeS="${1:-900}"; (($#)) && shift

    # All var. name with `__*` prefix are in JSON syntax.
    typeset __opNS= __opName= __opDelCS= __opDelOG= __opDelNS=
    typeset opSrc= opImg= opCSV=
    typeset e1=
    typeset -i wInt=0 wMax=0
    typeset -a opNSlst=()

    IFS=$'\n' read -rd '' \
        __opNS __opName __opDelCS __opDelOG __opDelNS \
        0< <(jq -c '
            (.namespace // ""), (.name // ""),
            (.delCatalogImage // 0), (.delOperatorGroup // 1),
            (.delNameSpace // 1)
        ' 0<<<"${opInJSON}") || true
    typeset -p ${!__op*} 1>&2
    [ "${__opName}" = '""' ] &&
        { echo "Operator's Name is NOT defined." 1>&2; return 1; }
    # Convert JSON syntax to Shell.
    for e1 in "${!__op@}"; do
        eval "typeset ${e1:2}"'="$(jq -cnr --argjson v "${!e1}" "\$v")"'
    done

    # Get the Operator Install Namespace.
    IFS=$'\n' read -d '' -ra opNSlst 0< <(
        oc get Subscriptions.operators.coreos.com -A \
            -o jsonpath=\
'{.items[?(@.spec.name == "'"${opName}"'")].metadata.namespace}'
    ) || true
    case ${#opNSlst[@]} in
      (0)
        echo "The Operator \`${opName}\` is NOT installed."
        return 0
        ;;
      (1)
        if [ -z "${opNS}" ]; then
            opNS=${opNSlst[0]}
            __opNS="$(jq -cn --arg opNS "${opNS}" '$opNS')"
        elif [ "${opNS}" != ${opNSlst[0]} ]; then
            cat - 0<<errEOF
The Operator \`${opName}\` is NOT installed in the NameSpace \`${opNS}\`,
instead it is in NameSpace \`${opNSlst[0]}\`.
Either remove \`namespace\` key from \`opInJSON\` parameter
OR set it to \`null\` or empty string or \`${opNSlst[0]}\`.
errEOF
            return 1
        fi
        ;;
      (*)
        e1=
        for e1 in "${opNSlst[@]}"; do
            [ "${opNS}" = "${e1}" ] && break
            e1=
        done
        typeset -p e1 opNSlst
        [ -z "${e1}" ] && {
            cat - 0<<errEOF
The Operator \`${opName}\` is NOT installed in the NameSpace \`${opNS}\`,
instead it is the following NameSpaces: ${opNSlst[@]@Q}.
The \`namespace\` key in \`opInJSON\` MUST be set to one of those list.
errEOF
            return 1
        }
        ;;
    esac

    # Get its Catalog Source and Image, if deletion of Catalog Source is
    #   requested.
    ((opDelCS)) && {
        IFS=$'\n' read -rd '' opSrc e1 0< <(
            oc -n "${opNS}" \
                get "Subscription.operators.coreos.com/${opName}" \
                -o jsonpath='{.spec.source}{"\n"}{.spec.sourceNamespace}'
        ) || true
        opImg="$(
            oc -n "${e1}" \
                get "CatalogSource.operators.coreos.com/${opSrc}" \
                -o jsonpath='{.spec.image}'
        )"
    }

    # Get the installed ClusterServiceVersion of the Operator.
    opCSV="$(
        oc -n "${opNS}" \
            get "Subscription.operators.coreos.com/${opName}" \
            -o jsonpath='{.status.installedCSV}'
    )"

    # Delete Subscription of the Operator.
    oc -n "${opNS}" delete Subscription.operators.coreos.com "${opName}" \
        --ignore-not-found --wait false

    # Monitor Subscription deletion.
    (   # Isolate `SECONDS` reset.
        # Subscription removal.
        SECONDS=0 wInt=10 wMax=300      # 5 Min. Max.
        while ((SECONDS < wMax)); do
            oc -n "${opName}" wait "Subscription.operators.coreos.com/${opName}" \
                --for delete --timeout 0 &> /dev/null && break || sleep ${wInt}
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Deleting Operator Subscription...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'Operator Subscription deletion.' 1>&2; exit 2; }
        true
    )

    # Remove the Operator.
    oc -n "${opNS}" delete ClusterServiceVersion "${opCSV}" \
        --ignore-not-found --wait false

    # Monitor Operator removal.
    (   # Isolate `SECONDS` reset.
        # Operator removal.
        SECONDS=0 wInt=10 wMax=300      # 5 Min. Max.
        while ((SECONDS < wMax)); do
            oc -n "${opName}" wait "ClusterServiceVersion/${opCSV}" \
                --for delete --timeout 0 &> /dev/null && break || sleep ${wInt}
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Removing Operator...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'Operator removal.' 1>&2; exit 2; }
        true
    )

    # Delete Catalog Source, if requested and there is no more Subscription
    #   to it.
    ((opDelCS)) && [ -z "$(
        oc get Subscription.operators.coreos.com \
            -A -o jsonpath=\
'{.items[?(@.spec.source == "'"${opSrc}"'")].metadata.name}'
    )" ] && {
        # Remove Catalog Source
        oc -n openshift-marketplace \
            delete CatalogSource.operators.coreos.com "${opSrc}" \
            --ignore-not-found --wait false

        # Monitor Catalog Source removal.
        (   # Isolate `SECONDS` reset.
            # Operator removal.
            SECONDS=0 wInt=10 wMax=300      # 5 Min. Max.
            while ((SECONDS < wMax)); do
                oc -n openshift-marketplace \
                    wait "CatalogSource.operators.coreos.com/${opSrc}" \
                    --for delete \
                    --timeout ${wInt}s &> /dev/null && break
                echo "Waited ${SECONDS}/${wMax} sec.: "\
'Removing Catalog Source...' 1>&2
            done
            ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'Catalog Source removal.' 1>&2; exit 2; }
            true
        )

        # Extract Image Content Source Policy (ICSP) so the corresponding ICSP
        #   can be deleted.
        e1=/icsp.yaml
        oc image extract "${opImg}" --file "${e1}" 2> /dev/null && {
            # Delete ICSP.
            e1="${e1##*/}"
            {
                oc delete -f "${e1}" --ignore-not-found | grep -q .
            } && ocp--crd--operator--00-core--mco--monitor-mcp-roll-out \
                ${mcWaitMCProTimeS} # Monitor MCP roll out.
            rm -rf "${e1}"
        }
    }

    # Delete Operator Group and NameSpace, if requested and there is no more
    #   Subscription in the Install NameSpace.
    (((opDelOG || opDelNS) && ! $(
        oc -n "${opNS}" get Subscription.operators.coreos.com \
            -o jsonpath='{.items}' |
        jq -r 'length'
    ))) && {
        # Delete Operator Group, if requested.
        ((opDelOG)) && {
            oc -n "${opNS}" delete OperatorGroup "$(
                oc -n "${opNS}" get OperatorGroups \
                    -o jsonpath='{.items[0].metadata.name}'
            )" --ignore-not-found --wait true
        }

        # Delete Operator Install NameSpace, if requested..
        ((opDelNS)) && {
            # Delete Operator Install NameSpace.
            oc delete Namespace "${opNS}" --ignore-not-found --wait false

            # Monitor Operator Install NameSpace deletion.
            (   # Isolate `SECONDS` reset.
                # Install NameSpace deletion.
                SECONDS=0 wInt=10 wMax=300      # 5 Min. Max.
                while ((SECONDS < wMax)); do
                    oc wait "Namespace/${opNS}" \
                        --for delete \
                        --timeout ${wInt}s 1> /dev/null && break
                    echo "Waited ${SECONDS}/${wMax} sec.: "\
'Deleting Operator Install NameSpace...' 1>&2
                done
                ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'Operator Install NameSpace deletion.' 1>&2; exit 2; }
                true
            )
        }
    }

    true
)}
```
</details>

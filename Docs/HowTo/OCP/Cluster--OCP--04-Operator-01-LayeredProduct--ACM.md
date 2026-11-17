# Cluster -- OpenShift -- Operator -- Layered Product -- Advanced Cluster Management
## References
<details><summary>Red Hat Advanced Cluster Manager</summary>

[TBD](https://)
</details>


## Operations
### Installation
<details><summary>Installing ACM</summary>

```shell
: ocp--crd--operator--01-lp--acm--install "$({ yq -o json e . | jq -c .; } 0<<'argEOF'
#version: 2.12.0    # Comment out or set to `null` or empty string to get latest version.
channel: '!default'
monitor: false
argEOF
)"
#   ocp--crd--operator--01-lp--acm--install '{"channel":"!default","monitor":false}'
function ocp--crd--operator--01-lp--acm--install () {(
    set -euo pipefail; shopt -s inherit_errexit
    typeset acmInJSON="${1:-{\}}"; (($#)) && shift

    # All var. name with `__*` prefix are in JSON syntax.
    typeset __acmVer= __acmChan= __acmMon= __acmCfg=
    typeset acmNS=
    typeset e1=
    typeset -i wInt=0 wMax=0

    IFS=$'\n' read -rd '' \
        __acmVer __acmChan __acmMon __acmCfg \
        0< <(jq -c '
            (.version // ""), (.channel // "!default"),
            (.monitor // false), (.config // "")
        ' 0<<<"${acmInJSON}") || true
    typeset -p ${!__acm*} 1>&2
    # Convert JSON syntax to Shell.
    for e1 in "${!__acm@}"; do
        eval "typeset ${e1:2}"'="$(jq -cnr --argjson v "${!e1}" "\$v")"'
    done

    # Install Operator.
    ocp--crd--operator--install "$({
        yq -o json e . |
        jq -c \
            --argjson acmVer "${__acmVer}" \
            --argjson acmChan "${__acmChan}" \
            --argjson acmMon "${__acmMon}" \
            --argjson acmCfg "${__acmCfg}" \
            '
                if ($acmVer != "") then
                    .version=("advanced-cluster-management.v" + $acmVer)
                end |
                .channel=$acmChan | .monitor=$acmMon |
                if ($acmCfg != "") then .config=$acmCfg end
            '
    } 0<<'argEOF'
namespace: open-cluster-management
name: advanced-cluster-management
version: '' # Comment out or set to `null` or empty string to get latest version.
source: redhat-operators
channel: ''
operatorGroup: open-cluster-management--group
targetNamespaces: '!install'
monitor: false
argEOF
)"

    # Create `MultiClusterHub` resource.
    acmNS="$(
        oc get Subscriptions.operators.coreos.com -A \
            -o jsonpath=\
'{.items[?(@.spec.name == "advanced-cluster-management")].metadata.namespace}'
    )"
    if ((! $(
        oc -n "${acmNS}" get MultiClusterHubs -o jsonpath='{.items}' |
        jq -r 'length'
    ))); then
        {
            oc create -f - --dry-run=client -o json --save-config |
            jq -c \
                --argjson acmNS "$(jq -cn --arg v "${acmNS}" '$v')" \
                '.metadata.namespace=$acmNS' |
            yq -p json -o yaml eval .
        } 0<<'ocEOF' | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: ''
spec:
  localClusterName: local-cluster
ocEOF
    fi

    # Monitor `MultiClusterHub` resource creation.
    (   # Isolate `SECONDS` reset.
        # Resource creation.
        SECONDS=0 wInt=10 wMax=900      # 15 Min. Max.
        while ((SECONDS < wMax)); do
            [ "$(
                oc -n "${acmNS}" get MultiClusterHubs \
                    -o jsonpath='{.items[0].status.phase}'
            )" != Running ] && sleep ${wInt} || break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Creating `MultiClusterHub` resource...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'`MultiClusterHub` resource creation.' 1>&2; exit 2; }
        # Final status.
        oc -n "${acmNS}" get MultiClusterHubs
    )

    true
)}
```
</details>


### Managed Cluster Deployment
<details><summary>Deploying Managed Cluster</summary>

```shell
: ocp--crd--operator--01-lp--acm--mng-cls--deploy "$(
    cat /dev/fd/{3..5} 3<<'argEOF' 4<<argEOF 5<<'argEOF' | \
    yq -o json e . | jq -c .
# The `.namespace` MUST always be the same as `.name`.
# Supported format for `installConfigURL` and `clusterPlatform.aws.awsCredURL`:
#   - File with absolute path: file:///path/to/file
#   - File with relative path: file://$(pwd)/path/to/file
#   - Shell Script: shell://$(<shellScript> | base64)
# The scripts MUST define the following (env.) var.s:
#   - installConfigURL:
#       typeset mcInsCfg=...contentOf--install-config.yaml--file...
#   - clusterPlatform.aws.awsCredURL:
#       export AWS_SECRET_ACCESS_KEY=...
#       export AWS_ACCESS_KEY_ID=...
name: edttj--acm-mc-1
dnsBaseDomain: test.lp.devcluster.openshift.com
ocpInstallerImageURLnoScheme: quay.io/openshift-release-dev/ocp-release:4.19.11-multi
clusterPlatform:
  aws:
    awsCredURL: file://$(pwd)/.data/acm-mng-cls/awsCred
argEOF
installConfigURL: file://$((cat <<'scrEOF'
$(pwd)/.data/acm-mng-cls/installConfig
scrEOF
    ) | base64 | base64 -d)
argEOF
pullSecretFile: .data/pullSecret
sshKeyPrvFile: ${HOME}/.ssh/openshift-qe.pem
KlusterletAddOns:
  applicationManager: true
  policyController: true
  searchCollector: true
  certPolicyController: true
argEOF
)"
#   ocp--crd--operator--01-lp--acm--mng-cls--deploy '{"name":"edttj--acm-mc-1","dnsBaseDomain":"test.lp.devcluster.openshift.com","ocpInstallerImageURLnoScheme":"quay.io/openshift-release-dev/ocp-release:4.19.11-multi","clusterPlatform":{"aws":{"awsCredURL":"file://$(pwd)/.data/acm-mng-cls/awsCred"}},"installConfigURL":"file://$(pwd)/.data/acm-mng-cls/installConfig","pullSecretFile":".data/pullSecret","sshKeyPrvFile":"${HOME}/.ssh/openshift-qe.pem","KlusterletAddOns":{"applicationManager":true,"policyController":true,"searchCollector":true,"certPolicyController":true}}'
function ocp--crd--operator--01-lp--acm--mng-cls--deploy () {(
    set -euo pipefail; shopt -s inherit_errexit
    typeset mcInJSON="${1:-{\}}"; (($#)) && shift
    typeset -i mcWaitDeplTimeS="${1:-5400}"; (($#)) && shift

    # All var. name with `__*` prefix are in JSON syntax.
    typeset __mcName= __mcBaseDom= __mcOCPinsImgURLnoSch= __mcPlat=
    typeset  __mcInsCfgURL= __mcPullSecrFile= __mcSSHkeyPrvFile= __mcKlusAO=
    typeset __mcPlat_type= __mcPlat_data=
    typeset __mcPlat_awsCredURL=
    typeset mcSecr_awsCred= mcSecr_insCfg= mcSecr_pullSecr= mcSecr_sshKeyPrv=
    typeset mcInsCfgScr= mcPlat_awsCredScr=
    typeset mcClsDir="${KUBECONFIG%/*}/acm--mcs"
    typeset mcKubeCfg= mcAdmUsr= mcAdmPwd=
    typeset mcKlusAO_crd= mcKlusAO_cfgNames=
    typeset e1= e2=
    typeset -i wInt=0 wMax=0
    typeset -a arr=()
    typeset -A mcKlusAO_cfg2agentNames=(
        [policyController]='(
            "config-policy-controller"
            "governance-policy-framework"
        )'
    )

    IFS=$'\n' read -rd '' \
        __mcName __mcBaseDom __mcOCPinsImgURLnoSch __mcPlat __mcInsCfgURL \
        __mcPullSecrFile __mcSSHkeyPrvFile __mcKlusAO \
        0< <(jq -c '
            (.name // ""), (.dnsBaseDomain // ""),
            (.ocpInstallerImageURLnoScheme // ""),
            (.clusterPlatform // ""), (.installConfigURL // ""),
            (.pullSecretFile // ""), (.sshKeyPrvFile // ""),
            (.KlusterletAddOns // "")
        ' 0<<<"${mcInJSON}") || true
    IFS=$'\n' read -rd '' \
        __mcPlat_type __mcPlat_data \
        0< <(jq -c '
            if ((keys | length) == 1) then
                (keys[0], .[keys[0]])
            end
        ' 0<<<"${__mcPlat}") || true
    case ${__mcPlat_type} in
      ('"aws"')
        IFS=$'\n' read -rd '' \
            __mcPlat_awsCredURL \
            0< <(jq -c '
                (.awsCredURL // "")
            ' 0<<<"${__mcPlat_data}") || true
        [ "${__mcPlat_awsCredURL}" = '""' ] &&
            { echo "ACM Managed Cluster's AWS Credential URL is NOT defined." 1>&2; return 1; }
        ;;
      (*)
        echo "Unsupported OCP Cluster Platform Type \`${__mcPlat_type:1:-1}\`." 1>&2
        return 1
        ;;
    esac
    typeset -p ${!__mc*} 1>&2
    [ "${__mcName}" = '""' ] &&
        { echo "ACM Managed Cluster's Name is NOT defined." 1>&2; return 1; }
    [ "${__mcBaseDom}" = '""' ] &&
        { echo "ACM Managed Cluster's DNS Base Domain is NOT defined." 1>&2; return 1; }
    [ "${__mcOCPinsImgURLnoSch}" = '""' ] &&
        { echo "ACM Managed Cluster's OCP Installer Image URL is NOT defined." 1>&2; return 1; }
    [ "${__mcInsCfgURL}" = '""' ]&&
        { echo "ACM Managed Cluster's AWS Credential URL is NOT defined." 1>&2; return 1; }
    [ "${__mcPullSecrFile}" = '""' ] &&
        { echo "ACM Managed Cluster's Pull Secret File is NOT defined." 1>&2; return 1; }
    [ "${__mcSSHkeyPrvFile}" = '""' ] &&
        { echo "ACM Managed Cluster's SSH Private Key File is NOT defined." 1>&2; return 1; }
    # Normalize paths.
    for e1 in \
        __mcInsCfgURL __mcPullSecrFile __mcSSHkeyPrvFile __mcPlat_awsCredURL \
    ; do
        eval "${e1}"'="$(jq -cn --arg v "'"$(jq -cnr --argjson v "${!e1}" '$v')"'" "\$v")"'
    done
    # Convert JSON syntax to Shell.
    for e1 in "${!__mc@}"; do
        eval "typeset ${e1:2}"'="$(jq -cnr --argjson v "${!e1}" "\$v")"'
    done
    # Get helper scripts.
    for e1 in \
        mcInsCfgURL mcPlat_awsCredURL \
    ; do
        case ${!e1} in
          (file://*)
            e2="${!e1#file://}"
            [ -e "${e2}" ] || {
                echo "File \`${e2}\` does NOT exist." 1>&2
                return 1
            }
            e1="${e1:0:-3}Scr"
            eval "${e1}=\$(cat ${e2@Q})"
            ;;
          (shell://*)
            e2="${!e1#shell://}"
            e1="${e1:2:-3}Scr"
            eval "${e1}=\$(echo ${e2@Q} | base64 -d)"
            ;;
          (*)
            echo "Not supported URL: ${!e1}"
            ;;
        esac
    done
    mcSecr_awsCred="${mcName}-aws-cred"
    mcSecr_insCfg="${mcName}-install-config"
    mcSecr_pullSecr="${mcName}-pull-secret"
    mcSecr_sshKeyPrv="${mcName}-ssh-private-key"

    ##  Deployment Phase.
    # Create ACM Managed Cluster NameSpace.
    #   It MUST always be the same as the ACM Managed Cluster Name itself,
    #   otherwise the import will fail.
    {
        oc create namespace "${mcName}" \
            --dry-run=client -o json --save-config
    } | oc apply -f -
    oc wait "Namespace/${mcName}" \
        --for jsonpath='{.status.phase}'=Active \
        --timeout 60s 1> /dev/null

    # Prepare Cluster Platform related settings.
    case ${mcPlat_type} in
      (aws)
        # Prepare AWS Credential.
        eval "$(
            exec 3>&1 1>&2
            eval "${mcPlat_awsCredScr}"
            typeset -p AWS_SECRET_ACCESS_KEY AWS_ACCESS_KEY_ID 1>&3 || echo false
        )"

        # Create Secret for AWS Credential.
        {
            oc -n "${mcName}" create secret generic "${mcSecr_awsCred}" \
                --type Opaque \
                --from-literal aws_access_key_id="${AWS_ACCESS_KEY_ID}" \
                --from-literal aws_secret_access_key="${AWS_SECRET_ACCESS_KEY}" \
                --dry-run=client -o yaml --save-config
        } | oc apply -f -
        ;;
    esac

    # Create `install-config.yaml` content.
    eval "$(
        exec 3>&1 1>&2
        eval "${mcInsCfgScr}"
        typeset -p mcInsCfg 1>&3 || echo false
    )"

    # Update `install-config.yaml` content.
    mcInsCfg="$({
        yq -p yaml -o json eval . |
        jq -c \
            --argjson mcName "${__mcName}" \
            --argjson mcBaseDom "${__mcBaseDom}" \
            '
                .baseDomain=$mcBaseDom |
                .metadata.name=$mcName
            ' |
        yq -p json -o yaml eval .
    } 0<<<"${mcInsCfg}")"

    # Create Secret for `install-config.yaml`.
    {
        oc -n "${mcName}" create secret generic "${mcSecr_insCfg}" \
            --type Opaque \
            --from-literal install-config.yaml="${mcInsCfg}" \
            --dry-run=client -o yaml --save-config
    } | oc apply -f -

    # Create Secret for Pull Secret.
    {
        oc -n "${mcName}" create secret generic "${mcSecr_pullSecr}"\
            --type=kubernetes.io/dockerconfigjson \
            --from-file .dockerconfigjson="${mcPullSecrFile}" \
            --dry-run=client -o yaml --save-config
    } | oc apply -f -

    # Create Secret for SSH Private Key.
    {
        oc -n "${mcName}" create secret generic "${mcSecr_sshKeyPrv}" \
            --type=Opaque \
            --from-file ssh-privatekey="${mcSSHkeyPrvFile}" \
            --dry-run=client -o yaml --save-config
    } | oc apply -f -

    # Deploy ACM Managed Cluster.
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --argjson mcName "${__mcName}" \
            --argjson mcBaseDom "${__mcBaseDom}" \
            --argjson mcOCPinsImgURLnoSch "${__mcOCPinsImgURLnoSch}" \
            --argjson mcPlat_k "${__mcPlat_type}" \
            --argjson mcInsCfg "$(
                echo "${mcInsCfg}" | yq -p yaml -o json eval .
            )" \
            --arg mcSecr_awsCred "${mcSecr_awsCred}" \
            --arg mcSecr_insCfg "${mcSecr_insCfg}" \
            --arg mcSecr_pullSecr "${mcSecr_pullSecr}" \
            --arg mcSecr_sshKeyPrv "${mcSecr_sshKeyPrv}" \
            '
                .metadata|=(
                    .name=$mcName | .namespace=$mcName |
                    .labels|=(
                        if ($mcPlat_k == "aws") then
                            .cloud="AWS" |
                            .region=$mcInsCfg.platform.aws.region
                        end
                    )
                ) |
                .spec|=(
                    .baseDomain=$mcBaseDom |
                    .clusterName=$mcName |
                    .platform|=(
                        if ($mcPlat_k == "aws") then
                            .aws={
                                "credentialsSecretRef": {"name": $mcSecr_awsCred},
                                "region": $mcInsCfg.platform.aws.region
                            }
                        end
                    ) |
                    .provisioning|=(
                        .installConfigSecretRef.name=$mcSecr_insCfg |
                        .releaseImage=$mcOCPinsImgURLnoSch |
                        .sshPrivateKeySecretRef.name=$mcSecr_sshKeyPrv
                    ) |
                    .pullSecretRef.name=$mcSecr_pullSecr
                )
            ' |
        yq -p json -o yaml eval .
    } 0<<'ocEOF' | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: ''
  namespace: ''
  labels:
    cloud: ''
    region: ''
    vendor: OpenShift
spec:
  baseDomain: ''
  clusterName: ''
  controlPlaneConfig:
    servingCertificates: {}
  installAttemptsLimit: 1
  platform: {}
  provisioning:
    installConfigSecretRef:
      name: ''
    releaseImage: ''
    sshPrivateKeySecretRef:
      name: ''
  pullSecretRef:
    name: ''
ocEOF

    # Monitor ACM Managed Cluster deployment.
    (   # Isolate `SECONDS` reset.
        # Cluster deployment.
        SECONDS=0 wInt=60 wMax="${mcWaitDeplTimeS}"
        while ((SECONDS < wMax)); do
            [ "$(
                oc -n "${mcName}" get "ClusterDeployment/${mcName}" \
                    -o jsonpath='{.spec.installed}'
            )" != true ] && sleep ${wInt} || break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Deploying ACM Managed Cluster...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'ACM Managed Cluster deployment.' 1>&2; exit 2; }
        # Cluster start-up.
        SECONDS=0 wInt=10 wMax=600      # 10 Min. Max.
        while ((SECONDS < wMax)); do
            [ "$(
                oc -n "${mcName}" get "ClusterDeployment/${mcName}" \
                    -o jsonpath='{.status.powerState}'
            )" != Running ] && sleep ${wInt} || break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Starting-up ACM Managed Cluster...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'ACM Managed Cluster start-up.' 1>&2; exit 2; }
        # Final status.
        oc -n "${mcName}" get "ClusterDeployment/${mcName}"
    )

    # Get `KUBECONFIG` file.
    mcClsDir+="/${mcName}"
    mkdir -p -- "${mcClsDir}/auth"
    mcKubeCfg="${mcClsDir}/kubecfg"
    oc -n "${mcName}" get "Secret/$(
        oc -n "${mcName}" get "ClusterDeployment/${mcName}" \
            -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}'
    )" -o jsonpath='{.data.kubeconfig}' |
        base64 -d > "${mcClsDir}/auth/kubeconfig"
    cp -f "${mcClsDir}/auth/kubeconfig" "${mcKubeCfg}"

    # Get `kubeadmin` password.
    { IFS=$'\n' read -rd '' mcAdmUsr mcAdmPwd || true; } 0< <(
        oc -n "${mcName}" get "Secret/$(
            oc -n "${mcName}" get "ClusterDeployment/${mcName}" \
                -o jsonpath='{.spec.clusterMetadata.adminPasswordSecretRef.name}'
        )" -o jsonpath='{.data.username}{"\n"}{.data.password}'
    )
    echo "${mcAdmPwd}" | base64 -d > "${mcClsDir}/auth/$(
        echo "${mcAdmUsr}" | base64 -d
    )-password"

    ##  Importing Phase.
    # Import ACM Managed Cluster.
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --argjson mcName "${__mcName}" \
            --argjson mcPlat_k "${__mcPlat_type}" \
            --argjson mcInsCfg "$(
                echo "${mcInsCfg}" | yq -p yaml -o json eval .
            )" \
            '
                .metadata|=(
                    .labels|=(
                        if ($mcPlat_k == "aws") then
                            .cloud="Amazon" |
                            .region=$mcInsCfg.platform.aws.region |
                            .name=$mcName
                        end
                    ) |
                    .name=$mcName
                )
            ' |
        yq -p json -o yaml eval .
    } 0<<'ocEOF' | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  labels:
    cloud: ''
    region: ''
    name: ''
    vendor: OpenShift
  name: ''
spec:
  hubAcceptsClient: true
ocEOF
#       # Wait until ACM Managed Cluster Import resource is ready.
#       (   # Isolate `SECONDS` reset.
#           # Import resource.
#           SECONDS=0 wInt=10 wMax=300      # 5 Min. Max.
#           while ((SECONDS < wMax)); do
#               oc -n "${mcName}" \
#                   wait "Secret/${mcName}-import" \
#                   --for create --timeout 0 &> /dev/null && break || sleep ${wInt}
#               echo "Waited ${SECONDS}/${wMax} sec.: "\
#   'Waiting for ACM Managed Cluster Import resource...' 1>&2
#           done
#           ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
#   'ACM Managed Cluster Import resource.' 1>&2; exit 2; }
#           true
#       )
#       # Install Klusterlet (CRD and all supporting Resources) on the Managed Cluster.
#       oc -n "${mcName}" get "Secret/${mcName}-import" \
#           -o jsonpath='{.data}' |
#           jq -r '.["crds.yaml"], "Ci0tLQo=", .["import.yaml"]' | # Put `\n---\n` as separator.
#           base64 -d |
#           oc --kubeconfig="${mcKubeCfg}" create -f - \
#               --dry-run=client -o yaml --save-config |
#           oc --kubeconfig="${mcKubeCfg}" apply -f - --dry-run=server

    # Monitor ACM Managed Cluster import.
    (   # Isolate `SECONDS` reset.
        # Cluster import.
        SECONDS=0 wInt=10 wMax=300      # 5 Min. Max.
        while ((SECONDS < wMax)); do
            [ "$(
                oc -n "${mcName}" get "ManagedCluster/${mcName}" \
                    -o jsonpath=\
'{.status.conditions[?(@.type == "ManagedClusterConditionAvailable")].status}'
            )" != True ] && sleep ${wInt} || break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Importing ACM Managed Cluster...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'ACM Managed Cluster import.' 1>&2; exit 2; }
        # Final status.
        oc -n "${mcName}" get "ManagedCluster/${mcName}"
    )

    ##  Configuration Phase.
    # Configure ACM Managed Cluster AddOns.
    mcKlusAO_crd="$(cat - 0<<'yamlEOF'
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: ''
  namespace: ''
spec:
  clusterName: ''
  clusterNamespace: ''
  clusterLabels:
    cloud: ''
    vendor: OpenShift
  applicationManager:
    enabled: false
  policyController:
    enabled: false
  searchCollector:
    enabled: false
  certPolicyController:
    enabled: false
yamlEOF
    )"
    read -rd '' mcKlusAO_cfgNames 0< <(
        {
            yq -p yaml -o json eval . |
            jq -c \
                --argjson mcKlusAO "${__mcKlusAO}" \
                '
                    .spec |
                    . as $obj |
                    keys_unsorted[] |
                    . as $key |
                    select(
                        (($obj[$key] | type) == "object") and
                        ($obj[$key] | has("enabled")) and
                        ($mcKlusAO | has($key)) and
                        ($mcKlusAO[$key] | type == "boolean")
                    ) |
                    "[\(.)]=\($mcKlusAO[.]|@json)"
                '
        } 0<<<"${mcKlusAO_crd}"
    ) || true
    eval "typeset -A mcKlusAO_cfgNames=(${mcKlusAO_cfgNames})"
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --argjson mcName "${__mcName}" \
            --argjson mcPlat_k "${__mcPlat_type}" \
            --argjson mcKlusAO "${__mcKlusAO}" \
            '
                .metadata|=(
                    .name=$mcName | .namespace=$mcName
                ) |
                .spec|=(
                    .clusterName=$mcName |
                    .clusterNamespace=$mcName |
                    .clusterLabels|=(
                        if ($mcPlat_k == "aws") then
                            .cloud="Amazon"
                        end
                    ) |
                    reduce (
                        . as $obj |
                        keys_unsorted[] |
                        . as $key |
                        select(
                            (($obj[$key] | type) == "object") and
                            ($obj[$key] | has("enabled")) and
                            ($mcKlusAO | has($key)) and
                            ($mcKlusAO[$key] | type == "boolean")
                        )
                    ) as $key (.; .[$key].enabled=$mcKlusAO[$key])
                )
            ' |
        yq -p json -o yaml eval .
    } 0<<<"${mcKlusAO_crd}" | oc apply -f -

    # Monitor ACM Managed Cluster AddOns configuration.
    (   # Isolate `SECONDS` reset.
        for e1 in "${!mcKlusAO_cfgNames[@]}"; do
            [ -v mcKlusAO_cfg2agentNames[${e1}] ] && continue
            mcKlusAO_cfg2agentNames[${e1}]="$(echo "${e1}" | sed 's/[A-Z]/-\L&/g')"
            mcKlusAO_cfg2agentNames[${e1}]="(${mcKlusAO_cfg2agentNames[${e1}]@Q})"
        done
        # AddOns configuration.
        SECONDS=0 wInt=10 wMax=300      # 5 Min. Max.
        while ((SECONDS < wMax)); do
            for e1 in "${!mcKlusAO_cfg2agentNames[@]}"; do
                eval "arr=${mcKlusAO_cfg2agentNames[${e1}]}"
                for e2 in "${!arr[@]}"; do
                    if [ "${mcKlusAO_cfgNames[${e1}]}" = true ]; then
                        [ "$(
                            oc -n "${mcName}" \
                                get "ManagedClusterAddOn/${arr[${e2}]}" \
                                -o jsonpath=\
'{.status.conditions[?(@.type == "Available")].status}'
                        )" != True ] || unset arr[${e2}]
                    else
                        oc -n "${mcName}" \
                            wait "ManagedClusterAddOn/${arr[${e2}]}" \
                            --for delete --timeout 0 &> /dev/null &&
                            unset arr[${e2}]
                    fi
                done
                ((${#arr[@]})) || {
                    unset mcKlusAO_cfg2agentNames[${e1}]
                    continue
                }
                mcKlusAO_cfg2agentNames[${e1}]="(${arr[@]@Q})"
            done
            ((${#mcKlusAO_cfg2agentNames[@]})) && sleep ${wInt} || break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Configuring ACM Managed Cluster AddOns...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'ACM Managed Cluster AddOns configuration.' 1>&2; exit 2; }
        # Final status.
        oc -n "${mcName}" get ManagedClusterAddOns
    )

    true
)}
```
</details>
<details><summary>Example for .clusterPlatform.aws.awsCredScript</summary>

```shell
eval "$(
    exec 3>&1 1>&2
    _BW__NOTE_NAME='note.AWS--IAMuser--OCPinstaller' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    exec bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        {
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
        }
        typeset -p AWS_SECRET_ACCESS_KEY AWS_ACCESS_KEY_ID 1>&3
        true
cmdEOF
    )"
)"
```
</details>
<details><summary>Example for .installConfigScript</summary>

```shell
{
    cpuType=0
    clName=edttj--tst-1
    dlDestPfx=ocp-install/4.19
    awsRgn=us-east-1
    baseDom=test.lp.devcluster.openshift.com
    case ${cpuType} in
      (0)
        cpuArch=arm64
        wrkNodeType='{}'
        dlURL='https://mirror.openshift.com/pub/openshift-v4/aarch64/clients/ocp/stable/openshift-install-linux-amd64.tar.gz'
        dlDestDir="${dlDestPfx}/aws/arm"
        ;;
      (1)
        cpuArch=amd64
        wrkNodeType='{"aws": {"type": "m6i.metal"}}'
        dlURL='https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-install-linux.tar.gz'
        dlDestDir="${dlDestPfx}/aws/x86"
        ;;
    esac
    pullSec="$(0< .data/pullSecret)"
    sshKey="$(0< "${HOME}/.ssh/openshift-qe.pub")"
    clsDir=mcTmp; mkdir --p "${clsDir}"

    # Download OCP Installer.
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
    {
        yq -p yaml -o json eval . |
        jq \
            --arg clName "${clName}" \
            --arg awsRgn "${awsRgn}" \
            --arg baseDom "${baseDom}" \
            --arg cpuArch "${cpuArch}" \
            --argjson wrkNodeType "${wrkNodeType}" \
            --arg pullSec "${pullSec}" \
            --arg sshKey "${sshKey}" \
            '
                .baseDomain=$baseDom |
                .compute[0]|=(
                    .architecture=$cpuArch |
                    .platform=$wrkNodeType
                ) |
                .metadata.name=$clName |
                .platform.aws.region=$awsRgn |
                .pullSecret=$pullSec |
                .sshKey=$sshKey
            ' |
        yq -p json -o yaml eval .
    } 0<<'fileEOF' 1> "${clsDir}/install-config.yaml"
apiVersion: v1
baseDomain:
compute:
  - architecture:
    name: worker
    platform:
metadata:
  name:
platform:
  aws:
    region:
pullSecret:
sshKey:
fileEOF
    # Update `install-config.yaml` with the rest mandatory information.
    "${dlDestDir}/openshift-install" --dir "${clsDir}/" create install-config
    # Empty `.pullSecret` as `hive` will inject it.
    yq -i eval '.pullSecret=""' "${clsDir}/install-config.yaml"
    # Store it in var.
    typeset mcInsCfg="$(0< "${clsDir}/install-config.yaml")"
    rm -rf "${clsDir}/"
}
```
</details>


### Managed Cluster Destruction
<details><summary>Destroying Managed Cluster</summary>

```shell
: ocp--crd--operator--01-lp--acm--mng-cls--destroy "$({ yq -o json e . | jq -c .; } 0<<'argEOF'
name: edttj--acm-mc-1
argEOF
)"
#   ocp--crd--operator--01-lp--acm--mng-cls--destroy '{"name":"edttj--acm-mc-1"}'
function ocp--crd--operator--01-lp--acm--mng-cls--destroy () {(
    set -euo pipefail; shopt -s inherit_errexit
    typeset mcInJSON="${1:-{\}}"; (($#)) && shift
    typeset -i mcWaitDestTimeS="${1:-1800}"; (($#)) && shift

    # All var. name with `__*` prefix are in JSON syntax.
    typeset __mcName=
    typeset mcClsDir="${KUBECONFIG%/*}/acm--mcs"
    typeset e1=
    typeset -i wInt=0 wMax=0

    IFS=$'\n' read -rd '' \
        __mcName \
        0< <(jq -c '
            (.name // "")
        ' 0<<<"${mcInJSON}") || true
    typeset -p ${!__mc*} 1>&2
    [ "${__mcName}" = '""' ] &&
        { echo "ACM Managed Cluster's Name is NOT defined." 1>&2; return 1; }
    # Convert JSON syntax to Shell.
    for e1 in "${!__mc@}"; do
        eval "typeset ${e1:2}"'="$(jq -cnr --argjson v "${!e1}" "\$v")"'
    done

    ##  Decommissioning Phase.
    # Decommission ACM Managed Cluster AddOns.
    oc -n "${mcName}" delete KlusterletAddonConfig "${mcName}" \
        --ignore-not-found --wait false

    # Monitor ACM Managed Cluster decommission.
    (   # Isolate `SECONDS` reset.
        # AddOns decommission.
        SECONDS=0 wInt=10 wMax=300      # 5 Min. Max.
        while ((SECONDS < wMax)); do
            oc -n "${mcName}" wait "KlusterletAddonConfig/${mcName}" \
                --for delete --timeout 0 &> /dev/null && break || sleep ${wInt}
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Decommissioning ACM Managed Cluster...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'ACM Managed Cluster decommission.' 1>&2; exit 2; }
        true
    )

    ##  Detachment Phase.
    #  ACM Managed Cluster.
    oc delete ManagedCluster "${mcName}" --ignore-not-found --wait false

    # Monitor ACM Managed Cluster detachment.
    (   # Isolate `SECONDS` reset.
        # Cluster detachment.
        SECONDS=0 wInt=10 wMax=300      # 5 Min. Max.
        while ((SECONDS < wMax)); do
            oc wait "ManagedCluster/${mcName}" \
                --for delete \
                --timeout ${wInt}s 1> /dev/null && break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Detaching ACM Managed Cluster...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'ACM Managed Cluster detachment.' 1>&2; exit 2; }
        true
    )

    ##  Destruction Phase.
    # Destroy ACM Managed Cluster.
    oc -n "${mcName}" delete ClusterDeployment "${mcName}" \
        --ignore-not-found --wait false

    # Monitor ACM Managed Cluster destruction.
    (   # Isolate `SECONDS` reset.
        # Cluster destruction.
        SECONDS=0 wInt=60 wMax="${mcWaitDestTimeS}"
        while ((SECONDS < wMax)); do
            oc -n "${mcName}" wait "ClusterDeployment/${mcName}" \
                --for delete --timeout 0 &> /dev/null && break || sleep ${wInt}
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Destroying ACM Managed Cluster...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'ACM Managed Cluster destruction.' 1>&2; exit 2; }
        true
    )

    # Delete ACM Managed Cluster directory.
    mcClsDir+="/${mcName}"
    rm -rf -- "${mcClsDir}/"

    # Delete ACM Managed Cluster NameSpace.
    oc delete Namespace "${mcName}" --ignore-not-found --wait false

    # Monitor ACM Managed Cluster deletion.
    (   # Isolate `SECONDS` reset.
        # NameSpace deletion.
        SECONDS=0 wInt=60 wMax="${mcWaitDestTimeS}"
        while ((SECONDS < wMax)); do
            oc wait "Namespace/${mcName}" \
                --for delete \
                --timeout ${wInt}s 1> /dev/null && break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Deleting ACM Managed Cluster NameSpace...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'ACM Managed Cluster NameSpace deletion.' 1>&2; exit 2; }
        true
    )

    true
)}
```
</details>


### Removal
<details><summary>Removing ACM</summary>

```shell
function ocp--crd--operator--01-lp--acm--remove () {(
    set -euo pipefail; shopt -s inherit_errexit
    typeset acmNS= mchName=
    typeset -i wInt=0 wMax=0

    # Delete `MultiClusterHub` resource.
    acmNS="$(
        oc get Subscriptions.operators.coreos.com -A \
            -o jsonpath=\
'{.items[?(@.spec.name == "advanced-cluster-management")].metadata.namespace}'
    )"
    [ -n "${acmNS}" ] && mchName="$(
        # The MCH Resource is a singleton.
        oc -n "${acmNS}" get MultiClusterHubs \
            -o jsonpath='{.items[*].metadata.name}'
    )"
    [ -n "${mchName}" ] && {
        oc -n "${acmNS}" delete MultiClusterHub "${mchName}" \
            --ignore-not-found --wait false

        # Monitor `MultiClusterHub` resource deletion.
        (   # Isolate `SECONDS` reset.
            # Resource deletion.
            SECONDS=0 wInt=10 wMax=900      # 15 Min. Max.
            while ((SECONDS < wMax)); do
                oc -n "${acmNS}" wait "MultiClusterHub/${mchName}" \
                    --for delete --timeout 0 &> /dev/null && break || sleep ${wInt}
                echo "Waited ${SECONDS}/${wMax} sec.: "\
'Deleting `MultiClusterHub` resource...' 1>&2
            done
            ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'`MultiClusterHub` resource deletion.' 1>&2; exit 2; }
            true
        )
    }

    # Remove Operator.
    ocp--crd--operator--remove '{"name":"advanced-cluster-management"}'

    true
)}
```
</details>

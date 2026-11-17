# Cluster -- OpenShift -- Operator -- Core Operator -- Machine Config Operator
## References
<details><summary>Machine Config Operator</summary>

[MCO](https://github.com/openshift/machine-config-operator)
</details>


## Operations
### Monitoring
<details><summary>Machine Config Pool (MSP) Roll Out</summary>

```shell
function ocp--crd--operator--00-core--mco--monitor-mcp-roll-out () {(set -e
    typeset -i mcWaitMCProTimeS="${1:-3600}"; (($#)) && shift

    # Monitor MCP roll out.
    (   # Isolate `SECONDS` reset.
        # Roll out starting.
        SECONDS=0 wInt=10 wMax=900      # 15 Min. Max.
        while ((SECONDS < wMax)); do
            oc wait MachineConfigPools \
                --all --for condition=updating \
                --timeout ${wInt}s 1> /dev/null && break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Starting MCP roll out...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'MCP roll out to start.' 1>&2; exit 2; }
        # Roll out completion.
        SECONDS=0 wInt=10 wMax=${mcWaitMCProTimeS}
        while ((SECONDS < wMax)); do
            oc wait MachineConfigPools \
                --all --for condition=updated \
                --timeout ${wInt}s 1> /dev/null && break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Completing MCP roll out...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'MCP roll out completion.' 1>&2; exit 2; }
        # Final status.
        oc get MachineConfigPools
    )

    true
)}
```
</details>


### Tips & Tricks
<details><summary>Health Check</summary>

```shell
# Check MCP states.
( set -euo pipefail; shopt -s inherit_errexit
    for e in {master,worker}; do
        oc get MachineConfigPool "${e}" -o jsonpath='{.status.configuration.name}{"\n"}'
        oc get Nodes -l "machineconfiguration.openshift.io/role=${e}" -o jsonpath="$(cat - 0<<'ocEOF'
{range .items[*]}
    {.metadata.name}{"\t"}
    {.metadata.annotations.machineconfiguration\.openshift\.io/current-config}{"\n"}
{end}
ocEOF
        )"
    done
true )
oc -n openshift-machine-config-operator get Pods
oc -n openshift-machine-config-operator logs --timestamps=true -l k8s-app=machine-config-controller
oc get CustomResourceDefinition/machineosconfigs.machineconfiguration.openshift.io
```
</details>
<details><summary>Restore Missing CRD from Cluster Release Information</summary>

 1. Find out the name of the CRD Document.
    ```shell
    # Get CRD Document.
    oc adm release info --contents | grep '...crdName...'
    ```
 2. Follow [Retrieving Document from Release Information](./Cluster--ReleaseInformation.md#tips-tricks).
</details>

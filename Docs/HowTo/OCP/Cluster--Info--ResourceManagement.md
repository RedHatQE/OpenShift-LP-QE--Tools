# Cluster -- Info -- Resource Management
## Operations
### Finding All Resources in A Namespace
<details><summary>Get All Resources</summary>

```shell
kubectl api-resources --namespaced -o name |
    xargs -n1 bash -uxc '
        kubectl -n "${1}" get "${2}" --ignore-not-found
    ' '' ...ns...
```
</details>
<details><summary>Get All Deletable Resources</summary>

```shell
kubectl api-resources --namespaced --verbs delete -o name |
    xargs -n1 bash -uxc '
        kubectl -n "${1}" get "${2}" --ignore-not-found
    ' '' ...ns...
```
</details>

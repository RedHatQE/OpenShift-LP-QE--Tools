# Cluster -- OpenShift -- Cluster
## Libraries
### Select Resources
<details><summary>Project</summary>

```shell
function _ocp--prim--GetPrj () {
    oc get Projects \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        --sort-by '{.metadata.name}' | fzf --header 'Select a Project.'
    return 0
}
```
</details>

# Cluster -- Info -- Release Information
## Operations
### Tips & Tricks
<details><summary>Retrieving Document</summary>

```shell
# Retrieving Document from Release Information.
( set -euo pipefail; shopt -s inherit_errexit
    typeset docNameRgx='...'
    oc adm release info --contents | awk '
        BEGIN{p=0}
        (p && /^#/){p=0; print "---"}
        (!p && /^# '"${docNameRgx}"'$/){p=1; print; next}
        p{print}
    '
true ) | yq | oc apply -f -
```
</details>

# Cluster -- Info -- User Management
## Operations
### User Certificate
<details><summary>Get Certificate Life Time for Certificate-Based Authentication</summary>

```shell
(
    _K8S__USR_NAME='...'
    oc config view --raw -o jsonpath='{.users[?(@.name == "'"${_K8S__USR_NAME}"'")].user.client-certificate-data}' | base64 -d | openssl x509 -text -noout | grep 'Not After'
); echo $?
```
</details>

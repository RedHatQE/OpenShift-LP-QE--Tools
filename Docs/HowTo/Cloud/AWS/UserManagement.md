# AWS User Management
## Permission Policy
### Check Action Permission
<details><summary>IAM Role</summary>

```shell
(
    actNames='...svcName...:...actionName...'
    roleName='...'
    aws iam simulate-principal-policy \
        --policy-source-arn "arn:aws:iam::$(
            aws sts get-caller-identity --output text --query Account
        ):role/${roleName}" \
        --action-names "${actNames}" \
        --output table \
        --query 'EvaluationResults[*].{
            Name:EvalActionName
            Permission:EvalDecision
        }'
)
```
</details>

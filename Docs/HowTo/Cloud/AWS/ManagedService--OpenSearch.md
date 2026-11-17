# AWS OpenSearch Service (Managed with AWS Cognito Integration)
## Setup
**Pre-requisites:**
  - Run [Cognito.md - User Pool - Cognito User Pool and IdP](Cognito.md#setup).
  - Run [Cognito.md - Identity Pool - Cognito Identity Pool](Cognito.md#setup) with:
    | Variable              | Value |
    |-----------------------|-------|
    | `_AWS__COG__ACTION`   | `0`   |
    **Notes:**
      - It creates the Identity Pool without linking the App. Client Provider, as the App. Client is auto-created by OpenSearch Domain creation.
  - Run [Cognito.md - IAM Roles - IAM App. Servicing Role](Cognito.md#setup) with:
    | Variable                      | Value                                     |
    |-------------------------------|-------------------------------------------|
    | `_AWS__COG__ACTION`           | `1`                                       |
    | `_AWS__COG__APP_POL_NAME`     | `AmazonOpenSearchServiceCognitoAccess`    |
    | `_AWS__COG__APP_PRINCIPAL`    | `es.amazonaws.com`                        |
  - The Federated IAM Role `${AWS_ACCOUNT_ID}-${_AWS__OS__MASTER_ROLE_SFX}` used for administrative access via `aws-saml.py` serves as the OpenSearch Master
    User.
<details><summary>Creating OpenSearch Domain</summary>

```shell
__SHELL=0 \
    _AWS__COG__IDP_NAME='...cogIdPname...' \
    _AWS__DNS_BASE_DOM='...dnsBaseDom...' \
    _AWS__DNS_SUB_DOM='' \
    _AWS__OS__DOM_NAME='...osDomName...' \
    _AWS__OS__ENG_VER='OpenSearch_X.YY' \
    _AWS__OS__INST_TYPE='r7g.large.search' \
    _AWS__OS__INST_CNT=1 \
    _AWS__OS__ZONE_CNT=0 \
    _AWS__OS__EBS_SZ=10 \
    _AWS__OS__MASTER_ROLE_SFX=poweruser \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    AWS_REGION='...awsRegion...' \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        {
            ((_AWS__RESET_PROFILE)) && {
                # Clean up the AWS CLI profile.
                sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
            }
            klist -s || kinit
            aws-saml.py \
                --region "${AWS_REGION}" \
                --target-profile "${_AWS__PROFILE}" \
                --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
            function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
            export -f aws
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset cogUsrPoolName="cog--${_AWS__COG__IDP_NAME}--up"
        typeset cogIdPoolName="cog--${_AWS__COG__IDP_NAME}--ip"
        typeset cogIAMroleApp="cog--${_AWS__COG__IDP_NAME}--role--app"
        typeset dnsHstFQDN="${_AWS__OS__DOM_NAME,,}${_AWS__DNS_SUB_DOM:+.${_AWS__DNS_SUB_DOM}}.${_AWS__DNS_BASE_DOM}"
        typeset cogUsrPoolID= cogIdPoolID= cogIAMroleAppARN=
        typeset r53ZoneID= acmCertARN= osMasterRoleARN= osEP=
        typeset -i wInt=0 wMax=0

        cogUsrPoolID="$(
            typeset _page= _cur= _id= _nextTkn=
            while true; do
                _page="$(
                    aws cognito-idp list-user-pools \
                        --max-results 60 \
                        ${_nextTkn:+--next-token "${_nextTkn}"} \
                        --output json
                )"
                _cur="$(jq -cr \
                    --arg name "${cogUsrPoolName}" \
                    '.UserPools[] | select(.Name == $name).Id' \
                0<<<"${_page}")"
                [ -n "${_cur}" ] && {
                    [ -n "${_id}" ] || [[ "${_cur}" == *$'\n'* ]] && {
                        : "ERROR: Multiple User Pools: ${cogUsrPoolName}"
                        exit 1
                    }
                    _id="${_cur}"
                }
                _nextTkn="$(jq -cr '(.NextToken // empty)' 0<<<"${_page}")"
                [ -z "${_nextTkn}" ] && break
            done
            [ -n "${_id}" ] || {
                : "ERROR: User Pool not found: ${cogUsrPoolName}"
                exit 1
            }
            echo "${_id}"
        )"
        cogIdPoolID="$(
            typeset _page= _cur= _id= _nextTkn=
            while true; do
                _page="$(
                    aws cognito-identity list-identity-pools \
                        --max-results 60 \
                        ${_nextTkn:+--next-token "${_nextTkn}"} \
                        --output json
                )"
                _cur="$(jq -cr \
                    --arg name "${cogIdPoolName}" \
                    '
                        .IdentityPools[] |
                        select(.IdentityPoolName == $name).IdentityPoolId
                    ' \
                0<<<"${_page}")"
                [ -n "${_cur}" ] && {
                    [ -n "${_id}" ] || [[ "${_cur}" == *$'\n'* ]] && {
                        : "ERROR: Multiple Identity Pools: ${cogIdPoolName}"
                        exit 1
                    }
                    _id="${_cur}"
                }
                _nextTkn="$(jq -cr '(.NextToken // empty)' 0<<<"${_page}")"
                [ -z "${_nextTkn}" ] && break
            done
            [ -n "${_id}" ] || {
                : "ERROR: Identity Pool not found: ${cogIdPoolName}"
                exit 1
            }
            echo "${_id}"
        )"
        cogIAMroleAppARN="$(
            aws iam get-role \
                --role-name "${cogIAMroleApp}" \
                --output text \
                --query 'Role.Arn'
        )"

        # Get Route 53 Hosted Zone ID.
        r53ZoneID="$(
            aws route53 list-hosted-zones-by-name \
                --dns-name "${_AWS__DNS_BASE_DOM}" \
                --output text \
                --query "HostedZones[?
                    (Name == \`\"${_AWS__DNS_BASE_DOM}.\"\`)
                ].Id" |
            cut -d/ -f3
        )"; [ -n "${r53ZoneID}" ]

        # Get or create ACM Certificate for Custom EndPoint.
        acmCertARN="$(
            acmCertARN="$(
                aws acm list-certificates \
                    --certificate-statuses ISSUED PENDING_VALIDATION \
                    --output text \
                    --query "CertificateSummaryList[?
                        contains(SubjectAlternativeNameSummaries, '${dnsHstFQDN}')
                    ].CertificateArn"
            )"
            [ -n "${acmCertARN}" ] && {
                [[ "${acmCertARN}" == *$'\t'* ]] && {
                    : "ERROR: Multiple ISSUED ACM Certificates for: ${dnsHstFQDN}"
                    exit 1
                }
                echo "${acmCertARN}"
                exit 0
            }
            aws acm request-certificate \
                --domain-name "${_AWS__OS__DOM_NAME,,}.${_AWS__DNS_BASE_DOM}" \
                --subject-alternative-names "${dnsHstFQDN}" \
                --validation-method DNS \
                --output text \
                --query 'CertificateArn'
        )"
        # Add DNS validation CNAMEs (all Domains) to Route 53.
        aws route53 change-resource-record-sets \
            --hosted-zone-id "${r53ZoneID}" \
            --change-batch "$(
                aws acm describe-certificate \
                    --certificate-arn "${acmCertARN}" \
                    --output json \
                    --query 'Certificate.DomainValidationOptions[].ResourceRecord' |
                jq -c '{Changes: [.[] | {
                    Action: "UPSERT",
                    ResourceRecordSet: {
                        Name: .Name,
                        Type: .Type,
                        TTL: 300,
                        ResourceRecords: [{Value: .Value}]
                    }
                }]}'
            )" \
            --no-cli-pager
        # Monitor for ACM Certificate validation.
        (   # Isolate `SECONDS` reset.
            SECONDS=0 wInt=30 wMax=3600     # 60 Min. Max.
            # ACM Certificate validation.
            while ((SECONDS < wMax)); do
                [ "$(
                    aws acm describe-certificate \
                        --certificate-arn "${acmCertARN}" \
                        --output text \
                        --query 'Certificate.Status'
                )" != "ISSUED" ] && sleep ${wInt} || break
                echo "Waited ${SECONDS}/${wMax} sec.: "\
'Validating for ACM Certificate...' 1>&2
            done
            ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'ACM Certificate validation.' 1>&2; exit 2; }
            # Final status.
            aws acm describe-certificate \
                --certificate-arn "${acmCertARN}" \
                --no-cli-pager
        )

        # Create OpenSearch Service-Linked Role.
        aws iam get-role \
            --role-name AWSServiceRoleForAmazonOpenSearchService \
            --no-cli-pager &> /dev/null || {
            aws iam create-service-linked-role \
                --aws-service-name opensearchservice.amazonaws.com \
                --no-cli-pager
            sleep 30    # Wait for IAM propagation.
        }

        # Create OpenSearch Domain.
        osMasterRoleARN="$(
            aws iam get-role \
                --role-name "${AWS_ACCOUNT_ID}-${_AWS__OS__MASTER_ROLE_SFX}" \
                --output text \
                --query 'Role.Arn'
        )"
        {
            aws opensearch describe-domain \
                --domain-name "${_AWS__OS__DOM_NAME}" \
                &> /dev/null ||
            aws opensearch create-domain \
                --domain-name "${_AWS__OS__DOM_NAME}" \
                --engine-version "${_AWS__OS__ENG_VER}" \
                --cluster-config "$(
                    jq -cn \
                        --arg type "${_AWS__OS__INST_TYPE}" \
                        --argjson nodeCnt "${_AWS__OS__INST_CNT}" \
                        --argjson zoneCnt "${_AWS__OS__ZONE_CNT}" \
                        '{
                            InstanceType: $type,
                            InstanceCount: $nodeCnt,
                            ZoneAwarenessEnabled: ($zoneCnt > 0)
                        } | (
                            if ($zoneCnt > 0) then
                                .ZoneAwarenessConfig
                                    .AvailabilityZoneCount=$zoneCnt
                            else . end
                        )'
                )" \
                --ebs-options \
"EBSEnabled=true,"\
"VolumeType=gp3,"\
"VolumeSize=${_AWS__OS__EBS_SZ}" \
                --access-policies "$(
                    jq -cn \
                        --arg acc "${AWS_ACCOUNT_ID}" \
                        --arg reg "${AWS_REGION}" \
                        --arg dom "${_AWS__OS__DOM_NAME}" \
                        '{
                            Version: "2012-10-17",
                            Statement: [{
                                Effect: "Allow",
                                Principal: {AWS: (
                                    "arn:aws:iam::" + $acc + ":root"
                                )},
                                Action: "es:*",
                                Resource: (
                                    "arn:aws:es:" + $reg + ":" + $acc +
                                    ":domain/" + $dom + "/*"
                                )
                            }, {
                                Effect: "Allow",
                                Principal: {AWS: "*"},
                                Action: "es:ESHttp*",
                                Resource: (
                                    "arn:aws:es:" + $reg + ":" + $acc +
                                    ":domain/" + $dom + "/*"
                                )
                            }]
                        }'
                )" \
                --cognito-options "$(
                    jq -cn \
                        --arg upID "${cogUsrPoolID}" \
                        --arg ipID "${cogIdPoolID}" \
                        --arg roleARN "${cogIAMroleAppARN}" \
                        '{
                            Enabled: true,
                            UserPoolId: $upID,
                            IdentityPoolId: $ipID,
                            RoleArn: $roleARN
                        }'
                )" \
                --encryption-at-rest-options 'Enabled=true' \
                --node-to-node-encryption-options 'Enabled=true' \
                --domain-endpoint-options "$(
                    jq -cn \
                        --arg hstFQDN "${dnsHstFQDN}" \
                        --arg certARN "${acmCertARN}" \
                        '{
                            EnforceHTTPS: true,
                            TLSSecurityPolicy: "Policy-Min-TLS-1-2-2019-07",
                            CustomEndpointEnabled: true,
                            CustomEndpoint: $hstFQDN,
                            CustomEndpointCertificateArn: $certARN
                        }'
                )" \
                --advanced-security-options "$(
                    jq -cn \
                        --arg masterARN "${osMasterRoleARN}" \
                        '{
                            Enabled: true,
                            InternalUserDatabaseEnabled: true,
                            MasterUserOptions: {MasterUserARN: $masterARN}
                        }'
                )" \
                --off-peak-window-options "$(
                    jq -cn \
                        '{
                            Enabled: true,
                            OffPeakWindow: {WindowStartTime: {
                                Hours: 6, Minutes: 0
                            }}
                        }'
                )" \
                --software-update-options 'AutoSoftwareUpdateEnabled=true' \
                --no-cli-pager
        }

        # Monitor OpenSearch Domain creation.
        (   # Isolate `SECONDS` reset.
            SECONDS=0 wInt=60 wMax=3600     # 60 Min. Max.
            # Domain creation.
            while ((SECONDS < wMax)); do
                [ "$(
                    aws opensearch describe-domain \
                        --domain-name "${_AWS__OS__DOM_NAME}" \
                        --output text \
                        --query 'DomainStatus.Processing'
                )" != "False" ] && sleep ${wInt} || break
                echo "Waited ${SECONDS}/${wMax} sec.: "\
'Creating OpenSearch Domain...' 1>&2
            done
            ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'OpenSearch Domain creation.' 1>&2; exit 2; }
            # Final status.
            aws opensearch describe-domain \
                --domain-name "${_AWS__OS__DOM_NAME}" \
                --no-cli-pager
        )

        osEP="$(
            aws opensearch describe-domain \
                --domain-name "${_AWS__OS__DOM_NAME}" \
                --output text \
                --query 'DomainStatus.Endpoint'
        )"

        # Create or update Route 53 Hosted Zone DNS CNAME Records.
        aws route53 change-resource-record-sets \
            --hosted-zone-id "${r53ZoneID}" \
            --change-batch "$(
                jq -cn \
                    --arg hstFQDN "${dnsHstFQDN}" \
                    --arg osEP "${osEP}" \
                    '{
                        Changes: [{
                            Action: "UPSERT",
                            ResourceRecordSet: {
                                Name: $hstFQDN,
                                Type: "CNAME",
                                TTL: 300,
                                ResourceRecords: [{Value: $osEP}]
                            }
                        }]
                    }'
            )" \
            --no-cli-pager

        # Show DNS Records.
        aws route53 list-resource-record-sets \
            --hosted-zone-id "${r53ZoneID}" \
            --query "ResourceRecordSets[?
                (Name == \`\"${dnsHstFQDN}.\"\`)
            ]" \
            --output table --no-cli-pager

        cat - 0<<txtEOF 1>&2
--------------------------------------------------------------------------------
OpenSearch Domain ready:
    Domain:     ${_AWS__OS__DOM_NAME}
    EndPoint:   ${osEP}
    Dashboards: https://${dnsHstFQDN}/_dashboards
--------------------------------------------------------------------------------
txtEOF

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Finalizing AWS Cognito Integration</summary>

 1. Update AWS Cognito User Pool App. Client CallBack and LogOut URLs.
    Run [Cognito.md - User Pool - User Pool App. Client](Cognito.md#setup) with:
    | Variable                      | Value                                             |
    |-------------------------------|---------------------------------------------------|
    | `_AWS__COG__ACTION`           | `0`                                               |
    | `_AWS__COG__CLIENT_NAME`      | `AmazonOpenSearchService-<osClientSfx>`           |
    | `_AWS__COG__CALLBACK_URLS`    | `https://<osFQDN>/_dashboards/app/home`           |
    | `_AWS__COG__LOGOUT_URLS`      | `https://<osFQDN>/_dashboards`                    |
    <details><summary>Helper Script</summary>

    ```shell
    ( set -euo pipefail; shopt -s inherit_errexit
        typeset osEP='...osEP...'
        typeset osFQDN='...osFQDN...'

        IFS=. read -ra sParts 0<<<"${osEP}"
        typeset osEPhash="${sParts[0]##*-}"
        typeset osDomName="${sParts[0]#search-}"; osDomName="${osDomName%-${osEPhash}}"
        typeset cogClientName="AmazonOpenSearchService-${osDomName}-${sParts[1]}-${osEPhash}"

        cat - 0<<txtEOF
    --------------------------------------------------------------------------------
    _AWS__COG__CLIENT_NAME:     ${cogClientName}
    _AWS__COG__CALLBACK_URLS:   https://${osFQDN}/_dashboards/app/home
    _AWS__COG__LOGOUT_URLS:     https://${osFQDN}/_dashboards
    --------------------------------------------------------------------------------
    txtEOF
    true )
    ```
    </details>

    **Notes:**
      - The `_AWS__COG__CLIENT_NAME` must match the App Client name that AWS OpenSearch Service automatically created in the User Pool when the domain was
        enabled with Cognito auth. The client is named `AmazonOpenSearchService-<osClientSfx>` (where `osClientSfx=<osDom>-<awsReg>-<randomHash>`) and cannot
        be renamed.
      - The `<osFQDN>` is the OpenSearch Dashboards FQDN (derive from the `Dashboards:` value in the domain creation output above).
 2. Create AWS Cognito Identity Pool.
    Run [Cognito.md - Identity Pool](Cognito.md#setup) with:
    | Variable                      | Value                                             |
    |-------------------------------|---------------------------------------------------|
    | `_AWS__COG__ACTION`           | `1`                                               |
    | `_AWS__COG__APP_NAME`         | `open-search`                                     |
    | `_AWS__COG__CLIENT_NAME`      | `AmazonOpenSearchService-<osClientSfx>`           |
 3. Create IAM Auth/Un-Auth Roles.
    Run [Cognito.md - IAM Roles - IAM Auth/Un-Auth Role](Cognito.md#setup) with:
    | Variable              | Value |
    |-----------------------|-------|
    | `_AWS__COG__ACTION`   | `1`   |
</details>
<details><summary>BootStrapping Access Control</summary>

**Note**:
  - Uses `awscurl` (SigV4) authenticated as the Master IAM Role.
  - Run **after** the Domain is ready and the Cognito CallBack URLs are updated.
```shell
__SHELL=0 \
    _AWS__COG__IDP_NAME='...cogIdPname...' \
    _AWS__OS__FQDN='...osFQDN...' \
    _AWS__OS__MASTER_ROLE_SFX=poweruser \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    AWS_REGION='...awsRegion...' \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        {
            ((_AWS__RESET_PROFILE)) && {
                # Clean up the AWS CLI profile.
                sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
            }
            klist -s || kinit
            aws-saml.py \
                --region "${AWS_REGION}" \
                --target-profile "${_AWS__PROFILE}" \
                --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
            function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
            export -f aws
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset cogIAMroleAuth="cog--${_AWS__COG__IDP_NAME}--role--auth"
        typeset cogIAMroleAuthARN=
        typeset osMasterRoleARN=
        typeset e=

        function awscurl () {
            command awscurl \
                --profile "${_AWS__PROFILE}" \
                --region "${AWS_REGION}" \
                --service es \
                "$@"
        }

        cogIAMroleAuthARN="$(
            aws iam get-role \
                --role-name "${cogIAMroleAuth}" \
                --output text \
                --query 'Role.Arn'
        )"; [ -n "${cogIAMroleAuthARN}" ]
        osMasterRoleARN="$(
            aws iam get-role \
                --role-name "${AWS_ACCOUNT_ID}-${_AWS__OS__MASTER_ROLE_SFX}" \
                --output text \
                --query 'Role.Arn'
        )"; [ -n "${osMasterRoleARN}" ]

        # Create Custom `dashboards_readonly` OpenSearch Role, i.e. R/O access
        #   to Dashboards Index Patterns only in Global Tenant.
        awscurl -X PUT \
            -H 'Content-Type: application/json' \
            -d "$(jq -cn '{
                cluster_permissions: [],
                index_permissions: [{
                    index_patterns: [".kibana*", ".opensearch_dashboards*"],
                    allowed_actions: [
                        "read",
                        "indices:admin/aliases/get",
                        "indices:admin/mappings/get"
                    ]
                }],
                tenant_permissions: [{
                    tenant_patterns: ["global_tenant"],
                    allowed_actions: ["kibana_all_read"]
                }]
            }')" \
            "https://${_AWS__OS__FQDN}/_plugins/_security/api/roles/dashboards_readonly"
        # Map Cognito IAM Auth Role to OpenSearch Roles:
        # - Custom `dashboards_readonly` (R/O access to Dashboards Index
        #   Patterns in global tenant).
        # NOTE: Do NOT map `opensearch_dashboards_read_only` to the Cognito
        #   IAM Auth Role. Despite its name suggesting R/O UI controls, it is
        #   a Dashboards-level kiosk mode that hides Discover and Management
        #   apps entirely — making Dashboards unusable for data exploration.
        #   R/O enforcement is handled at the backend via `kibana_all_read`
        #   tenant permissions; saves fail server-side even if UI shows buttons.
        for e in dashboards_readonly; do
            awscurl -X PUT \
                -H 'Content-Type: application/json' \
                -d "$(jq -c \
                    --arg beRole "${cogIAMroleAuthARN}" \
                    --arg role "${e}" \
                    '{
                        backend_roles: (
                            ((.[$role].backend_roles // []) + [$beRole]) |
                            unique
                        )
                    }' \
                0< <(
                    awscurl -X GET \
                        "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${e}" \
                        2> /dev/null ||
                    echo 'null'
                ))" \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${e}"
        done

        # Show Roles assigned to Cognito IAM Auth Role.
        {
            awscurl -X GET \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping" |
            jq -r \
                --arg beRole "${cogIAMroleAuthARN}" \
                '["Roles:"] + [
                    to_entries[] |
                    select(.value.backend_roles | contains([$beRole])) |
                    "    \(.key)"
                ] | .[]'
        }

#       # Map Master IAM Role to OpenSearch Roles:
#       # - Built-In `all_access` (full access to all Cluster, Index, and
#       #   Tenant operations).
#       # - Built-In `security_manager` (access to the Security Plugin REST
#       #   API for managing roles, mappings, etc.).
#       awscurl -X PATCH \
#           -H 'Content-Type: application/json' \
#           -d "$(
#               jq -cn \
#                   --arg beRole "${osMasterRoleARN}" \
#                   '[{
#                       op: "add",
#                       path: "/all_access/backend_roles/-",
#                       value: $beRole
#                   }, {
#                       op: "add",
#                       path: "/security_manager/backend_roles/-",
#                       value: $beRole
#                   }]'
#           )" \
#           "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping"

        # Show Roles assigned to Master IAM Role.
        {
            awscurl -X GET \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping" |
            jq -r \
                --arg beRole "${osMasterRoleARN}" \
                '["Roles:"] + [
                    to_entries[] |
                    select(.value.backend_roles | contains([$beRole])) |
                    "    \(.key)"
                ] | .[]'
        }

        cat - 0<<txtEOF 1>&2
--------------------------------------------------------------------------------
OpenSearch Security BootStrapped.
    Dashboards: https://${_AWS__OS__FQDN}/_dashboards
      - SSO via Google will grant R/O Dashboards access.
      - Log in once with Google to register your Cognito User Identity, then
        run the next section to grant Administrator Access.
--------------------------------------------------------------------------------
txtEOF

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Granting Administrator Access to SSO User</summary>

**Pre-requisite:**
  - User must have logged in at least once via Google SSO.
```shell
__SHELL=0 \
    _AWS__COG__IDP_NAME='...cogIdPname...' \
    _AWS__OS__FQDN='...osFQDN...' \
    _AWS__OS__ADM_EML='...osAdmEMail...' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    AWS_REGION='...awsRegion...' \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        {
            ((_AWS__RESET_PROFILE)) && {
                # Clean up the AWS CLI profile.
                sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
            }
            klist -s || kinit
            aws-saml.py \
                --region "${AWS_REGION}" \
                --target-profile "${_AWS__PROFILE}" \
                --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
            function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
            export -f aws
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset cogUsrPoolName="cog--${_AWS__COG__IDP_NAME}--up"
        typeset cogUsrPoolID= osAdmUsr=

        function awscurl () {
            command awscurl \
                --profile "${_AWS__PROFILE}" \
                --region "${AWS_REGION}" \
                --service es \
                "$@"
        }

        cogUsrPoolID="$(
            typeset _page= _cur= _id= _nextTkn=
            while true; do
                _page="$(
                    aws cognito-idp list-user-pools \
                        --max-results 60 \
                        ${_nextTkn:+--next-token "${_nextTkn}"} \
                        --output json
                )"
                _cur="$(jq -cr \
                    --arg name "${cogUsrPoolName}" \
                    '.UserPools[] | select(.Name == $name).Id' \
                0<<<"${_page}")"
                [ -n "${_cur}" ] && {
                    [ -n "${_id}" ] || [[ "${_cur}" == *$'\n'* ]] && {
                        : "ERROR: Multiple User Pools: ${cogUsrPoolName}"
                        exit 1
                    }
                    _id="${_cur}"
                }
                _nextTkn="$(jq -cr '(.NextToken // empty)' 0<<<"${_page}")"
                [ -z "${_nextTkn}" ] && break
            done
            [ -n "${_id}" ] || { : "ERROR: User Pool not found: ${cogUsrPoolName}"; exit 1; }
            echo "${_id}"
        )"
        osAdmUsr="$(
            aws cognito-idp list-users \
                --user-pool-id "${cogUsrPoolID}" \
                --filter "email = \"${_AWS__OS__ADM_EML}\"" \
                --output text \
                --query 'Users[0].Username'
        )"; [ "${osAdmUsr}" != "None" ]
        osAdmUsr="Cognito/${cogUsrPoolID}/${osAdmUsr}"

        # Add User to `all_access` + `security_manager`.
        for e in all_access security_manager; do
            awscurl -X PUT \
                -H 'Content-Type: application/json' \
                -d "$(jq -c \
                    --arg usr "${osAdmUsr}" \
                    --arg role "${e}" \
                    '{
                        backend_roles: (.[$role].backend_roles // []),
                        users: (((.[$role].users // []) + [$usr]) | unique)
                    }' \
                0< <(
                    awscurl -X GET \
                        "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${e}" \
                        2> /dev/null ||
                    echo 'null'
                ))" \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${e}"
        done

        # Show Roles assigned to User.
        {
            awscurl -X GET \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping" |
            jq -r \
                --arg usr "${osAdmUsr}" \
                '["Roles:"] + [
                    to_entries[] |
                    select(.value.users | contains([$usr])) |
                    "    \(.key)"
                ] | .[]'
        }

        true
cmdEOF
    )"; echo $?
```
</details>


## Maintenance
<details><summary>Scaling, Upgrading OpenSearch Domain, and/or Updating Service Software</summary>

```shell
__SHELL=0 \
    _AWS__OS__DOM_NAME='...osDomName...' \
    _AWS__OS__SCALE=0 \
    _AWS__OS__INST_TYPE='r7g.large.search' \
    _AWS__OS__INST_CNT=1 \
    _AWS__OS__ZONE_CNT=0 \
    _AWS__OS__EBS_SZ=10 \
    _AWS__OS__ENG_VER_NEW='' \
    _AWS__OS__SVC_SW_UPD=0 \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    AWS_REGION='...awsRegion...' \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        {
            ((_AWS__RESET_PROFILE)) && {
                # Clean up the AWS CLI profile.
                sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
            }
            klist -s || kinit
            aws-saml.py \
                --region "${AWS_REGION}" \
                --target-profile "${_AWS__PROFILE}" \
                --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
            function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
            export -f aws
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset -i wInt=0 wMax=0

        # Scale OpenSearch Domain.
        if ((_AWS__OS__SCALE)); then
            aws opensearch update-domain-config \
                --domain-name "${_AWS__OS__DOM_NAME}" \
                --cluster-config "$(
                    jq -cn \
                        --arg type "${_AWS__OS__INST_TYPE}" \
                        --argjson nodeCnt "${_AWS__OS__INST_CNT}" \
                        --argjson zoneCnt "${_AWS__OS__ZONE_CNT}" \
                        '{
                            InstanceType: $type,
                            InstanceCount: $nodeCnt,
                            ZoneAwarenessEnabled: ($zoneCnt > 0)
                        } | (
                            if ($zoneCnt > 0) then
                                .ZoneAwarenessConfig
                                    .AvailabilityZoneCount=$zoneCnt
                            else . end
                        )'
                )" \
                --ebs-options \
"EBSEnabled=true,"\
"VolumeType=gp3,"\
"VolumeSize=${_AWS__OS__EBS_SZ}" \
                --no-cli-pager

            # Monitor OpenSearch Domain scaling.
            (   # Isolate `SECONDS` reset.
                SECONDS=0 wInt=60 wMax=3600     # 60 Min. Max.
                while ((SECONDS < wMax)); do
                    [ "$(
                        aws opensearch describe-domain \
                            --domain-name "${_AWS__OS__DOM_NAME}" \
                            --output text \
                            --query 'DomainStatus.Processing'
                    )" != "False" ] && sleep ${wInt} || break
                    echo "Waited ${SECONDS}/${wMax} sec.: "\
'Scaling OpenSearch Domain...' 1>&2
                done
                ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'OpenSearch Domain scaling.' 1>&2; exit 2; }
                # Final status.
                aws opensearch describe-domain \
                    --domain-name "${_AWS__OS__DOM_NAME}" \
                    --no-cli-pager
            )
        fi

        # Upgrade OpenSearch Engine Version.
        if {
            [ -n "${_AWS__OS__ENG_VER_NEW}" ] &&
            [ "$(
                aws opensearch describe-domain \
                    --domain-name "${_AWS__OS__DOM_NAME}" \
                    --output text \
                    --query 'DomainStatus.EngineVersion'
            )" != "${_AWS__OS__ENG_VER_NEW}" ]
        }; then
            aws opensearch upgrade-domain \
                --domain-name "${_AWS__OS__DOM_NAME}" \
                --target-version "${_AWS__OS__ENG_VER_NEW}" \
                --no-cli-pager

            # Monitor OpenSearch Engine upgrade.
            (   # Isolate `SECONDS` reset.
                SECONDS=0 wInt=60 wMax=7200     # 120 Min. Max.
                while ((SECONDS < wMax)); do
                    [ "$(
                        aws opensearch describe-domain \
                            --domain-name "${_AWS__OS__DOM_NAME}" \
                            --output text \
                            --query 'DomainStatus.UpgradeProcessing'
                    )" != "False" ] && sleep ${wInt} || break
                    echo "Waited ${SECONDS}/${wMax} sec.: "\
'Upgrading OpenSearch Engine...' 1>&2
                done
                ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'OpenSearch Engine upgrade.' 1>&2; exit 2; }
                # Final status.
                aws opensearch describe-domain \
                    --domain-name "${_AWS__OS__DOM_NAME}" \
                    --no-cli-pager
            )
        fi

        # Update Service Software.
        if ((_AWS__OS__SVC_SW_UPD)); then
            aws opensearch start-service-software-update \
                --domain-name "${_AWS__OS__DOM_NAME}" \
                --schedule-at NOW \
                --no-cli-pager

            # Monitor Service Software Update.
            (   # Isolate `SECONDS` reset.
                SECONDS=0 wInt=60 wMax=3600     # 60 Min. Max.
                while ((SECONDS < wMax)); do
                    typeset swUpdSt="$(
                        aws opensearch describe-domain \
                            --domain-name "${_AWS__OS__DOM_NAME}" \
                            --output text \
                            --query 'DomainStatus.ServiceSoftwareOptions.UpdateStatus'
                    )"
                    [ "${swUpdSt}" = 'COMPLETED' ] && break || sleep ${wInt}
                    echo "Waited ${SECONDS}/${wMax} sec.: "\
'Updating Service Software...' 1>&2
                done
                ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'Service Software Update.' 1>&2; exit 2; }
                # Final status.
                aws opensearch describe-domain \
                    --domain-name "${_AWS__OS__DOM_NAME}" \
                    --no-cli-pager
            )
        fi

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Disk Usage</summary>

```shell
__SHELL=0 \
    _AWS__OS__FQDN='...osFQDN...' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    AWS_REGION='...awsRegion...' \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        {
            ((_AWS__RESET_PROFILE)) && {
                # Clean up the AWS CLI profile.
                sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
            }
            klist -s || kinit
            aws-saml.py \
                --region "${AWS_REGION}" \
                --target-profile "${_AWS__PROFILE}" \
                --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
            function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
            export -f aws
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        function awscurl () {
            command awscurl \
                --profile "${_AWS__PROFILE}" \
                --region "${AWS_REGION}" \
                --service es \
                "$@"
        }

        # Cluster level.
        awscurl -X GET \
            "https://${_AWS__OS__FQDN}/_cluster/stats" |
        jq -r '.nodes.fs | (
            "Cluster Storage Usage:",
            "    Total:      \(((.total_in_bytes     * 10) / (1024*1024*1024)) | round | (. / 10)) GiB",
            "    Free:       \(((.free_in_bytes      * 10) / (1024*1024*1024)) | round | (. / 10)) GiB",
            "    Available:  \(((.available_in_bytes * 10) / (1024*1024*1024)) | round | (. / 10)) GiB"
        )'

        # Node level.
        awscurl -X GET \
            "https://${_AWS__OS__FQDN}/_cat/allocation?v&pretty"

        true
cmdEOF
    )"; echo $?
```
</details>


## Administrative Tasks
<details><summary>Managing Index with ISM Retention Policy</summary>

```shell
__SHELL=0 \
    _AWS__OS__ACTION=1 \
    _AWS__OS__FQDN='...osFQDN...' \
    _AWS__OS__ISM__KEEP_DAYS=90 \
    _AWS__OS__ISM__RO_IDX_MIN_SIZE='1gb' \
    _AWS__OS__ISM__RO_IDX_MIN_DAYS=30 \
    _AWS__OS__IDX__PFX='...osIdxPfx...' \
    _AWS__OS__IDX__SHARDS=1 \
    _AWS__OS__IDX__REPLS=0 \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    AWS_REGION='...awsRegion...' \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        {
            ((_AWS__RESET_PROFILE)) && {
                # Clean up the AWS CLI profile.
                sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
            }
            klist -s || kinit
            aws-saml.py \
                --region "${AWS_REGION}" \
                --target-profile "${_AWS__PROFILE}" \
                --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
            function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
            export -f aws
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset ismPolName="${_AWS__OS__IDX__PFX}--retention"
        typeset idxTemplName="${_AWS__OS__IDX__PFX}--template"
        typeset ismSeqNo= ismPriTerm= freeIdx=

        case ${_AWS__OS__ACTION} in (-2|-1|0|1);; (*)false;; esac

        function awscurl () {
            command awscurl \
                --profile "${_AWS__PROFILE}" \
                --region "${AWS_REGION}" \
                --service es \
                "$@"
        }

        case ${_AWS__OS__ACTION} in
          (-2)
            # Delete matching Indices.
            ( set +x
                typeset line= idxName=
                while IFS= read -r line; do
                    [ -n "${line}" ] || continue
                    idxName="${line:2}"
                    if [ "${line:0:1}" = 'A' ]; then
                        awscurl -X DELETE \
                            "https://${_AWS__OS__FQDN}/*/_alias/${idxName}" ||
                        true
                    else
                        awscurl -X DELETE \
                            "https://${_AWS__OS__FQDN}/${idxName}" ||
                        true
                    fi
                done 0< <(
                    jq -nr \
                        --argjson idxLst "$(
                            awscurl -X GET \
                                "https://${_AWS__OS__FQDN}/_cat/indices/${_AWS__OS__IDX__PFX}*?format=json"
                        )" \
                        --argjson alsLst "$(
                            awscurl -X GET \
                                "https://${_AWS__OS__FQDN}/_cat/aliases/${_AWS__OS__IDX__PFX}*?format=json"
                        )" \
                        '
                            [
                                ($alsLst[]? | {name: .alias, isAlias: true}),
                                ($idxLst[]? | {name: .index, isAlias: false})
                            ]
                            | unique_by([.name, .isAlias])
                            | sort_by(.name)
                            | .[]
                            | "\(if .isAlias then "A" else " " end) \(.name)"
                        ' |
                    fzf \
                        -m \
                        --bind alt-a:toggle-all \
                        --header 'Select indices to delete.'
                )
            true )
            ;;
          (-1)
            # Delete Index Template and ISM Retention Policy.
            {
                awscurl -X DELETE \
                    "https://${_AWS__OS__FQDN}/_index_template/${idxTemplName}" ||
                true
                awscurl -X DELETE \
                    "https://${_AWS__OS__FQDN}/_plugins/_ism/policies/${ismPolName}" ||
                true
            }
            ;;
          (0)
            # List Index Templates, Retention Policies, and matching Indices.
            {
                jq -cn \
                    --argjson tmpl "$(
                        awscurl -X GET \
                            "https://${_AWS__OS__FQDN}/_index_template"
                    )" \
                    --argjson pol "$(
                        awscurl -X GET \
                            "https://${_AWS__OS__FQDN}/_plugins/_ism/policies"
                    )" \
                    --argjson idxCfg "$(
                        awscurl -X GET \
                            "https://${_AWS__OS__FQDN}/_cat/indices?format=json"
                    )" \
                    --argjson idxLst "$(
                        awscurl -X GET \
                            "https://${_AWS__OS__FQDN}/_plugins/_ism/explain/*?show_policy=true"
                    )" \
                    '
                        ([
                            $pol.policies[]? |
                            {key: ._id, value: .policy.states}
                        ] | from_entries) as $polMap |
                        ([
                            $idxCfg[]? |
                            {key: .index, value: {
                                shards: (.pri | tonumber? // "N/A"),
                                replicas: (.rep | tonumber? // "N/A")
                            }}
                        ] | from_entries) as $iCfg |
                        [
                            $idxLst |
                            to_entries[] |
                            select(
                                (.key | startswith(".") | not) and
                                (.value | type == "object")
                            )
                        ] as $allUsrIdx |
                        ([
                            $tmpl.index_templates[]? |
                            select(.name | endswith("--template")) |
                            .name as $tName | (
                                .index_template |
                                (.index_patterns // []) as $ptrn |
                                (
                                    .template.settings.index //
                                    .template.settings //
                                    {}
                                ) as $s |
                                (($s.number_of_shards | tonumber?) // "N/A") as $shrd |
                                (($s.number_of_replicas | tonumber?) // "N/A") as $rplc |
                                (
                                    $s["plugins.index_state_management.policy_id"] //
                                    $s.plugins.index_state_management.policy_id //
                                    "None"
                                ) as $tPolId |
                                ([ $allUsrIdx[] | select(
                                    .key as $idxName |
                                    $ptrn | any(
                                        . as $p |
                                        $idxName |
                                        test("^" + (
                                            $p |
                                            gsub(
                                                "(?<c>[\\\\.^$+(){}\\[\\]|])";
                                                "\\\(.c)"
                                            ) |
                                            gsub("\\*"; ".*") |
                                            gsub("\\?"; ".")
                                        ) + "$")
                                    )
                                ) | {(.key): [
                                    {"State": (
                                        .value.state.name // "N/A"
                                    )},
                                    {"Shards": (
                                        $iCfg[.key].shards // "N/A"
                                    )},
                                    {"Replicas": (
                                        $iCfg[.key].replicas // "N/A"
                                    )},
                                    {"Retention Policy": (
                                        (
                                            .value.policy.policy_id //
                                            .value.policy_id //
                                            .value["index.plugins.index_state_management.policy_id"] //
                                            .value["index.opendistro.index_state_management.policy_id"] //
                                            "None"
                                        ) as $iPolId |
                                        {
                                            "name": $iPolId,
                                            "states": (
                                                .value.policy.states //
                                                $polMap[$iPolId] //
                                                "N/A"
                                            )
                                        }
                                    )}
                                ]}]) as $mIdx |
                                {($tName): [
                                    {"Patterns": $ptrn},
                                    {"Shards": $shrd},
                                    {"Replicas": $rplc},
                                    {"ISM Retention Policy": {
                                        "name": $tPolId,
                                        "states": ($polMap[$tPolId] // "N/A")
                                    }},
                                    {"Indexes": $mIdx}
                                ]}
                            )
                        ] | add) // {}
                    ' |
                yq -p json -o yaml eval .
            }
            ;;
          (1)
            # Create or update ISM Retention Policy.
            eval "$(
                jq -r '"
                    ismSeqNo=\(._seq_no // "")
                    ismPriTerm=\(._primary_term // "")
                "' 0< <(
                    awscurl -X GET \
                        "https://${_AWS__OS__FQDN}/_plugins/_ism/policies/${ismPolName}" \
                        2> /dev/null ||
                    echo '{}'
                )
            )"
            awscurl -X PUT \
                -H 'Content-Type: application/json' \
                -d "$(
                    jq -cn \
                        --arg idxPfx "${_AWS__OS__IDX__PFX}" \
                        --arg rtnDays "${_AWS__OS__ISM__KEEP_DAYS}d" \
                        --arg roMinSize "${_AWS__OS__ISM__RO_IDX_MIN_SIZE}" \
                        --arg roMinDays "${_AWS__OS__ISM__RO_IDX_MIN_DAYS}d" \
                        '{
                            policy: {
                                description: "Retention policy for `\($idxPfx)*` indices.",
                                default_state: "active",
                                ism_template: {
                                    index_patterns: ["\($idxPfx)*"],
                                    priority: 100
                                },
                                states: [{
                                    name: "active",
                                    actions: [{rollover: {
                                        min_size: $roMinSize,
                                        min_index_age: $roMinDays,
                                        prevent_empty_rollover: true
                                    }}],
                                    transitions: [{
                                        state_name: "delete",
                                        conditions: {min_index_age: $rtnDays}
                                    }]
                                }, {
                                    name: "delete",
                                    actions: [{delete: {}}],
                                    transitions: []
                                }]
                            }
                        }'
                )" \
"https://${_AWS__OS__FQDN}/_plugins/_ism/policies/${ismPolName}"\
"${ismSeqNo:+?if_seq_no=${ismSeqNo}&if_primary_term=${ismPriTerm}}"

            # Create or update Index Template.
            awscurl -X PUT \
                -H 'Content-Type: application/json' \
                -d "$(
                    jq -cn \
                        --arg polName "${ismPolName}" \
                        --arg idxPfx "${_AWS__OS__IDX__PFX}" \
                        --argjson idxShrd "${_AWS__OS__IDX__SHARDS}" \
                        --argjson idxRplc "${_AWS__OS__IDX__REPLS}" \
                        '{
                            index_patterns: ["\($idxPfx)*"],
                            template: {
                                settings: {
                                    "plugins.index_state_management.policy_id": $polName,
                                    "plugins.index_state_management.rollover_alias": $idxPfx,
                                    number_of_shards: $idxShrd,
                                    number_of_replicas: $idxRplc
                                }
                            }
                        }'
                )" \
                "https://${_AWS__OS__FQDN}/_index_template/${idxTemplName}"

            # Bootstrap initial numbered index and RollOver Write Alias.
            if {
                awscurl -X GET \
                    "https://${_AWS__OS__FQDN}/_alias/${_AWS__OS__IDX__PFX}" \
                    2> /dev/null |
                jq -e 'has("error")' &> /dev/null
            } then
                # Get the first free numbered index.
                freeIdx="${_AWS__OS__IDX__PFX}-$(printf '%06d' "$(
                    awscurl -X GET \
                        "https://${_AWS__OS__FQDN}/_cat/indices/${_AWS__OS__IDX__PFX}-*?format=json" \
                        2> /dev/null |
                    jq -r \
                        --arg pfx "${_AWS__OS__IDX__PFX}" \
                        '
                            [
                                .[].index |
                                ltrimstr($pfx + "-") |
                                select(test("^\\d{6}$")) |
                                tonumber
                            ] | (
                                if (length == 0) then 0
                                else ((sort[-1] + 1) % 1000000)
                                end
                            )
                        '
                )")"

                # Check if this index exists (sequence wrapped).
                {
                    awscurl -X GET \
                        "https://${_AWS__OS__FQDN}/${freeIdx}" \
                        2> /dev/null |
                    jq -e 'has("error")' &> /dev/null
                } || {
                    echo \
                        "ERROR: Index \`${freeIdx}\` already exists"\
                        '(sequence wrapped). Cannot proceed.'\
                        1>&2
                    exit 1
                }

                # Check if the alias name is a real index.
                if {
                    awscurl -X GET \
                        "https://${_AWS__OS__FQDN}/${_AWS__OS__IDX__PFX}" \
                        2> /dev/null |
                    jq -e 'has("error")' &> /dev/null
                } then
                    # Create alias.
                    awscurl -X PUT \
                        -H 'Content-Type: application/json' \
                        -d "$(
                            jq -cn \
                                --arg alias "${_AWS__OS__IDX__PFX}" \
                                '{aliases: {($alias): {is_write_index: true}}}'
                        )" \
                        "https://${_AWS__OS__FQDN}/${freeIdx}"
                else
                    # Reindex unnumbered index to free numbered index.
                    awscurl -X POST \
                        -H 'Content-Type: application/json' \
                        -d "$(
                            jq -cn \
                                --arg src "${_AWS__OS__IDX__PFX}" \
                                --arg dst "${freeIdx}" \
                                '{source: {index: $src}, dest: {index: $dst}}'
                        )" \
                        "https://${_AWS__OS__FQDN}/_reindex?wait_for_completion=true"
                    awscurl -X DELETE \
                        "https://${_AWS__OS__FQDN}/${_AWS__OS__IDX__PFX}"
                    awscurl -X POST \
                        -H 'Content-Type: application/json' \
                        -d "$(
                            jq -cn \
                                --arg idx "${freeIdx}" \
                                --arg alias "${_AWS__OS__IDX__PFX}" \
                                '{actions: [{add: {
                                    index: $idx,
                                    alias: $alias,
                                    is_write_index: true
                                }}]}'
                        )" \
                        "https://${_AWS__OS__FQDN}/_aliases"
                fi
            fi
            ;;
        esac

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Managing Tenant</summary>

```shell
__SHELL=0 \
    _AWS__OS__ACTION=1 \
    _AWS__OS__FQDN='...osFQDN...' \
    _AWS__OS__TEN__NAME='...osTenantName...' \
    _AWS__OS__TEN__DESC='...osTenantDesc...' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=admin \
   x_AWS__SES_TO=3600 \
    AWS_REGION='...awsRegion...' \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        {
            ((_AWS__RESET_PROFILE)) && {
                # Clean up the AWS CLI profile.
                sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
            }
            klist -s || kinit
            aws-saml.py \
                --region "${AWS_REGION}" \
                --target-profile "${_AWS__PROFILE}" \
                --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
            function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
            export -f aws
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        case ${_AWS__OS__ACTION} in (-1|0|1);; (*)false;; esac

        function awscurl () {
            command awscurl \
                --profile "${_AWS__PROFILE}" \
                --region "${AWS_REGION}" \
                --service es \
                "$@"
        }

        case ${_AWS__OS__ACTION} in
          (-1)
            # Delete Tenant.
            {
                awscurl -X DELETE \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/tenants/${_AWS__OS__TEN__NAME}" ||
                true
            }
            ;;
          (0)
            # List Tenants.
            {
                awscurl -X GET \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/tenants" |
                jq -r 'keys[]'
            }
            ;;
          (1)
            # Create or update Tenant.
            awscurl -X PUT \
                -H 'Content-Type: application/json' \
                -d "$(
                    jq -cn \
                        --arg desc "${_AWS__OS__TEN__DESC}" \
                        '{description: $desc}'
                )" \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/tenants/${_AWS__OS__TEN__NAME}"
            ;;
        esac

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Managing Role</summary>

```shell
#   _AWS__OS__IDX__PERMS supported values (ignored if `_AWS__OS__IDX__PAT` is
#   an empty string):
#     R/O   - Read only.
#     W/O   - Write only.
#     R/W   - Read and write.
#     CRUD  - Full Index Data Access.
#     ADM   - Full Index authority (CRUD + Index management).
#   _AWS__OS__TEN__PERMS supported values (ignored if `_AWS__OS__TEN__PAT` is
#   an empty string):
#     R/O   - View Dashboards and saved objects only.
#     R/W   - View and modify Dashboards and saved objects.
__SHELL=0 \
    _AWS__OS__ACTION=1 \
    _AWS__OS__FQDN='...osFQDN...' \
    _AWS__OS__IDX__PAT='' \
    _AWS__OS__IDX__PERMS='R/O' \
    _AWS__OS__TEN__PAT='' \
    _AWS__OS__TEN__PERMS='R/O' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=admin \
   x_AWS__SES_TO=3600 \
    AWS_REGION='...awsRegion...' \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        {
            ((_AWS__RESET_PROFILE)) && {
                # Clean up the AWS CLI profile.
                sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
            }
            klist -s || kinit
            aws-saml.py \
                --region "${AWS_REGION}" \
                --target-profile "${_AWS__PROFILE}" \
                --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
            function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
            export -f aws
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset idxPerms= clsPerms= tenPerms=
        typeset roleName=\
"${_AWS__OS__IDX__PAT:+idx__$(
    _AWS__OS__IDX__PAT="${_AWS__OS__IDX__PAT//\*/..all..}"
    echo "${_AWS__OS__IDX__PAT//\?/..any..}"
)__${_AWS__OS__IDX__PERMS/\//}}"\
"${_AWS__OS__TEN__PAT:+${_AWS__OS__IDX__PAT:+--}ten__$(
    _AWS__OS__TEN__PAT="${_AWS__OS__TEN__PAT//\*/..all..}"
    echo "${_AWS__OS__TEN__PAT//\?/..any..}"
)__${_AWS__OS__TEN__PERMS/\//}}"; [ -n "${roleName}" ]

        case ${_AWS__OS__ACTION} in (-1|0|1);; (*)false;; esac
        case ${_AWS__OS__IDX__PERMS} in
          (R/O)
            idxPerms='["read"]'
            clsPerms='['\
'"cluster_composite_ops_ro", '\
'"cluster:monitor/main", '\
'"cluster:monitor/health", '\
'"cluster:monitor/state"'\
']'
            ;;
          (W/O)
            idxPerms='["write", "indices:admin/create"]'
            clsPerms='["cluster_composite_ops", "cluster:monitor/main"]'
            ;;
          (R/W)
            idxPerms='["read", "write", "indices:admin/create"]'
            clsPerms='['\
'"cluster_composite_ops", '\
'"cluster:monitor/main", '\
'"cluster:monitor/health", '\
'"cluster:monitor/state"'\
']'
            ;;
          (CRUD)
            idxPerms='['\
'"crud", '\
'"indices:admin/create", '\
'"indices:admin/*template/*", '\
'"indices:admin/mapping*", '\
'"indices:admin/refresh*"'\
']'
            clsPerms='["cluster_composite_ops", "cluster_monitor"]'
            ;;
          (ADM)
            idxPerms='["indices_all"]'
            clsPerms='["cluster_composite_ops", "cluster_monitor"]'
            ;;
          (*)   false;;
        esac
        case ${_AWS__OS__TEN__PERMS} in
          (R/O) tenPerms='["kibana_all_read"]';;
          (R/W) tenPerms='["kibana_all_write"]';;
          (*)   false;;
        esac

        function awscurl () {
            command awscurl \
                --profile "${_AWS__PROFILE}" \
                --region "${AWS_REGION}" \
                --service es \
                "$@"
        }

        case ${_AWS__OS__ACTION} in
          (-1)
            # Delete Role.
            {
                awscurl -X DELETE \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/roles/${roleName}" ||
                true
            }
            ;;
          (0)
            # List Roles.
            {
                awscurl -X GET \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/roles" |
                jq -r 'keys[] | select(
                    startswith("idx__") or startswith("ten__")
                )'
            }
            ;;
          (1)
            # Create or update Role.
            awscurl -X PUT \
                -H 'Content-Type: application/json' \
                -d "$(
                    jq -cn \
                        --argjson clsPerms "${clsPerms}" \
                        --arg idxPat "${_AWS__OS__IDX__PAT}" \
                        --argjson idxPerms "${idxPerms}" \
                        --arg tenPat "${_AWS__OS__TEN__PAT}" \
                        --argjson tenPerms "${tenPerms}" \
                        '(
                            if ($idxPat != "") then {
                                cluster_permissions: $clsPerms,
                                index_permissions: [{
                                    index_patterns: [$idxPat],
                                    allowed_actions: $idxPerms
                                }]
                            } else {} end
                        ) + (
                            if ($tenPat != "") then {
                                tenant_permissions: [{
                                    tenant_patterns: [$tenPat],
                                    allowed_actions: $tenPerms
                                }]
                            } else {} end
                        )'
                )" \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/roles/${roleName}"
            ;;
        esac

        case ${_AWS__OS__ACTION} in
          (-1|1)
            # Show Role.
            awscurl -X GET \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/roles/${roleName}"
            ;;
        esac

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Managing Service Account</summary>

```shell
#   Role assignment is optional. Set `_AWS__OS__ROLE_NAME` to empty string to
#       skip it.
__SHELL=0 \
    _AWS__OS__ACTION=1 \
    _AWS__OS__FQDN='...osFQDN...' \
    _AWS__OS__CRD_USR='...osCrdUsr...' \
    _AWS__OS__CRD_PWD_CHG=0 \
    _AWS__OS__ROLE_NAME='' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=admin \
   x_AWS__SES_TO=3600 \
    _BW__NOTE_NAME='...bwNoteName...' \
    _GSM__CTR_IMG='...gsmCtrImg...' \
    _GSM__SEC_COL='...gsmSecCol...' \
    _GSM__SEC_PATH__GRP='...gsmSecPathGrp...' \
    _GSM__SEC_PATH__FLD__USR='...gsmSecPathFldUsr...' \
    _GSM__SEC_PATH__FLD__PWD='...gsmSecPathFldPwd...' \
   x_VAULT_MOUNT='...vaultMount...' \
   x_VAULT_KEY_PATH='...vaultKeyPath...' \
   x_VAULT_KEY_USR='...vaultKeyUsr...' \
   x_VAULT_KEY_PWD='...vaultKeyPwd...' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    AWS_REGION='...awsRegion...' \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
   xVAULT_ADDR='...vaultAddr...' \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        {
            ((_AWS__RESET_PROFILE)) && {
                # Clean up the AWS CLI profile.
                sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
            }
            klist -s || kinit
            aws-saml.py \
                --region "${AWS_REGION}" \
                --target-profile "${_AWS__PROFILE}" \
                --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
            function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
            export -f aws
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        {
            typeset __shOpt="$(shopt -po xtrace)"; set +x
            [ -n "${BW_SESSION}" ] && bw sync || {
                echo 'You do NOT have an active and sync:ed BitWarden Session!!!' 1>&2
                exit 1
            }
            eval "${__shOpt}"; unset __shOpt
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset bwData= bwSubFld="cred.${_AWS__OS__CRD_USR}"
        typeset crdUsr= crdPwd= role=

        case ${_AWS__OS__ACTION} in
            (-2|0|2)    ;;
            (-1|1)      [ -n "${_BW__NOTE_NAME}" ];;
            (*)         false;;
        esac

        function awscurl () {
            command awscurl \
                --profile "${_AWS__PROFILE}" \
                --region "${AWS_REGION}" \
                --service es \
                "$@"
        }

        crdUsr="$(
            echo -n "${_AWS__OS__CRD_USR}" |
            python3 -c "$(cat - 0<<'scrEOF'
import sys, urllib.parse
print(urllib.parse.quote(sys.stdin.read()), end='')
scrEOF
            )"
        )"

        [ -z "${_BW__NOTE_NAME}" ] || {
            typeset __shOpt="$(shopt -po xtrace)"; set +x
            bwData="$(bw get item "${_BW__NOTE_NAME}")" || {
                echo "You may NOT have access to BitWarden Note \`${_BW__NOTE_NAME}\`." 1>&2
                exit 1
            }
            { {
                bw encode 0<<<"${bwData}" |
                bw edit item "$(jq -cr '.id' 0<<<"${bwData}")" 1> /dev/null
            } || {
                echo "You do NOT have R/W access to BitWarden Note \`${_BW__NOTE_NAME}\`." 1>&2
                exit 1
            }; } && bw sync 1> /dev/null && bwData="$(bw get item "${_BW__NOTE_NAME}")"
            eval "${__shOpt}"; unset __shOpt
        }

        case ${_AWS__OS__ACTION} in
          (-2)
            # Remove Role.
            [ -n "${_AWS__OS__ROLE_NAME}" ] && {
                awscurl -X PUT \
                    -H 'Content-Type: application/json' \
                    -d "$(jq -c \
                        --arg usr "${_AWS__OS__CRD_USR}" \
                        --arg role "${_AWS__OS__ROLE_NAME}" \
                        '{
                            backend_roles: (.[$role].backend_roles // []),
                            users: ((.[$role].users // []) | map(select(. != $usr)))
                        }' \
                    0< <(
                        awscurl -X GET \
                            "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${_AWS__OS__ROLE_NAME}" \
                            2> /dev/null ||
                        echo 'null'
                    ))" \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${_AWS__OS__ROLE_NAME}"
            }
            ;;
          (-1)
            # Delete User.
            while IFS= read -r role; do
                awscurl -X PUT \
                    -H 'Content-Type: application/json' \
                    -d "$(jq -c \
                        --arg usr "${_AWS__OS__CRD_USR}" \
                        --arg role "${role}" \
                        '{
                            backend_roles: (.[$role].backend_roles // []),
                            users: ((.[$role].users // []) | map(select(. != $usr)))
                        }' \
                    0< <(
                        awscurl -X GET \
                            "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${role}" \
                            2> /dev/null ||
                        echo 'null'
                    ))" \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${role}"
            done 0< <(
                awscurl -X GET \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping" |
                jq -r \
                    --arg usr "${_AWS__OS__CRD_USR}" \
                    'to_entries[] | select(.value.users[]? == $usr) | .key'
            )
            {
                awscurl -X DELETE \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/internalusers/${crdUsr}" ||
                true
            }
            ;;
          (0)
            # List Users.
            {
                awscurl -X GET \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/internalusers" |
                jq -r 'keys[]'
            }
            ;;
          (1)
            # Create or update User.
            typeset __shOpt="$(shopt -po xtrace)"; set +x
            crdPwd="$( set +x
                ((_AWS__OS__CRD_PWD_CHG)) || {
                    crdPwd="$(jq -cr \
                        --arg fn__c "${bwSubFld}" \
                        '
                            .fields[]? | select(.name == $fn__c).value |
                            fromjson | (.pwd // "")
                        ' \
                    0<<<"${bwData}")"
                    [ -z "${crdPwd}" ] || { echo "${crdPwd}"; false; }
                } && {
                    while (
                        ((${#crdPwd} < 32)) ||
                        ! [[ "${crdPwd}" =~ [[:upper:]] ]] ||
                        ! [[ "${crdPwd}" =~ [[:lower:]] ]] ||
                        ! [[ "${crdPwd}" =~ [[:digit:]] ]] ||
                        ! [[ "${crdPwd}" =~ [+=._-] ]]
                    ); do
                        crdPwd="$(
                            openssl rand 256 | LC_ALL=c tr -dc '[:alnum:]+=._-'
                        )"
                        crdPwd="${crdPwd:0:32}"
                    done
                    echo "${crdPwd}"
                }
                awscurl -X PUT \
                    -H 'Content-Type: application/json' \
                    -d "$(jq -cn --arg pwd "${crdPwd}" '{password: $pwd}')" \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/internalusers/${crdUsr}" \
                    1>&2
            true )"
            eval "${__shOpt}"; unset __shOpt
            [ -n "${_AWS__OS__ROLE_NAME}" ] && {
                awscurl -X PUT \
                    -H 'Content-Type: application/json' \
                    -d "$(jq -c \
                        --arg usr "${_AWS__OS__CRD_USR}" \
                        --arg role "${_AWS__OS__ROLE_NAME}" \
                        '{
                            backend_roles: (.[$role].backend_roles // []),
                            users: (((.[$role].users // []) + [$usr]) | unique)
                        }' \
                    0< <(
                        awscurl -X GET \
                            "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${_AWS__OS__ROLE_NAME}" \
                            2> /dev/null ||
                        echo 'null'
                    ))" \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${_AWS__OS__ROLE_NAME}"
            }
            ;;
        esac

        case ${_AWS__OS__ACTION} in
          (-2|1|2)
            # Show User and assigned Roles.
            awscurl -X GET \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/internalusers/${crdUsr}"
            {
                awscurl -X GET \
                    "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping" |
                jq -r \
                    --arg usr "${_AWS__OS__CRD_USR}" \
                    '["Roles:"] + [
                        to_entries[] |
                        select(.value.users | contains([$usr])) |
                        "    \(.key)"
                    ] | .[]'
            }
            ;;
        esac

        # Update BitWarden.
        [ -z "${_BW__NOTE_NAME}" ] || ( set +x
            case ${_AWS__OS__ACTION} in
              (-1)
                bwData="$(jq -r \
                    --arg fn__c "${bwSubFld}" \
                    '.fields|=map(select(.name != $fn__c))' \
                0<<<"${bwData}")"
                bw encode 0<<<"${bwData}" | bw edit item "$(jq -cr '.id' 0<<<"${bwData}")" 1> /dev/null
                ;;
              (1)
                bwData="$(jq -r \
                    --arg fn__c "${bwSubFld}" \
                    --rawfile fv__c <( set +x
                        jq -cnj \
                            --arg usr "${_AWS__OS__CRD_USR}" \
                            --arg pwd "${crdPwd}" \
                            '{usr: $usr, pwd: $pwd}'
                    true ) \
                    '.fields|=((. // []) | (
                        map(select(.name != $fn__c)) +
                        [{name: $fn__c, value: $fv__c, type: 1}]
                    ))' \
                0<<<"${bwData}")"
                bw encode 0<<<"${bwData}" | bw edit item "$(jq -cr '.id' 0<<<"${bwData}")" 1> /dev/null
                ;;
            esac
        true )

        # Update Google Secret Manager (GSM).
        [ -z "${_GSM__SEC_COL}" ] || [ -z "${_GSM__SEC_PATH__GRP}" ] || [ \
            -z "${_GSM__SEC_PATH__FLD__USR}" ] || [ -z "${_GSM__SEC_PATH__FLD__PWD}" \
        ] || ( set +x
            function gsm-cli () {
                podman run --rm -i \
                    -u 0:0 \
                    -e CLOUDSDK_CONFIG=/gcloud \
                    -e GOOGLE_CLOUD_QUOTA_PROJECT=openshift-ci-secrets \
                    --env-file <(echo _GSM__SEC_VAL) \
                    -v "${HOME}/.config/gcloud:/gcloud:z" \
                    --entrypoint bash \
                    -- \
                    "${_GSM__CTR_IMG}" \
                    -c \
                    "$@"
            }
            function gsm-norm-path () {
                # Must follow encoding in
                #   `https://github.com/openshift/ci-tools/blob/main/pkg/gsm-validation/gsm.go` (`NormalizeName()`).
                printf '%s' "$(awk '{
                    while (match($0, /_{2,}/)) {
                        printf "%s", substr($0, 1, (RSTART-1))
                        n = RLENGTH
                        printf "--"
                        for (i=1; i<=n; i++) printf "u"
                        printf "--"
                        $0 = substr($0, (RSTART+RLENGTH))
                    }
                    printf "%s", $0
                }' 0<<<"${1//./--dot--}")"
            }

            typeset gsmSecLst= e=
            typeset -i gsmSecExistUsr=0 gsmSecExistPwd=0
            typeset -x _GSM__SEC_VAL=

            typeset gsmSecPathUsr="$(
                gsm-norm-path "${_GSM__SEC_PATH__GRP}/${_GSM__SEC_PATH__FLD__USR}"
            )"
            typeset gsmSecPathPwd="$(
                gsm-norm-path "${_GSM__SEC_PATH__GRP}/${_GSM__SEC_PATH__FLD__PWD}"
            )"

            gcloud auth application-default print-access-token &> /dev/null || {
                echo 'Logging in to Google Cloud...'
                gcloud auth application-default login --no-launch-browser
            } || {
                echo 'You may NOT have access to Google Cloud.' 1>&2
                exit 1
            }
            gsmSecLst="$(gsm-cli "$(cat - 0<<scrEOF
python3 main.py list \
    -c ${_GSM__SEC_COL@Q} \
    -o json
scrEOF
            )")" 2>/dev/null || {
                echo \
                    'You do NOT have access to GSM Collection'\
                    "\`${_GSM__SEC_COL}\`."\
                    1>&2
                exit 1
            }
            for e in Usr Pwd; do
                typeset -n gsmSecItemRef="gsmSecPath${e}"
                typeset -n gsmSecFlagRef="gsmSecExist${e}"
                gsmSecFlagRef=$(jq -r --arg p "${gsmSecItemRef}" '
                    (index($p) // -1) + 1
                ' 0<<<"${gsmSecLst}")
            done

            case ${_AWS__OS__ACTION} in
              (-1)
                for e in Usr Pwd; do
                    typeset -n gsmSecItemRef="gsmSecPath${e}"
                    typeset -n gsmSecFlagRef="gsmSecExist${e}"
                    ((gsmSecFlagRef)) && {
                        gsm-cli "$(cat - 0<<scrEOF
python3 main.py delete \
    -c ${_GSM__SEC_COL@Q} \
    ${gsmSecItemRef@Q}
scrEOF
                        )" 1> /dev/null
                    } || true   # Ignore error (may not have delete permission).
                done
                ;;
              (1)
                for e in Usr Pwd; do
                    typeset -n gsmSecItemRef="gsmSecPath${e}"
                    typeset -n gsmSecFlagRef="gsmSecExist${e}"
                    if [ "${e}" = 'Usr' ]; then
                        _GSM__SEC_VAL="${_AWS__OS__CRD_USR}"
                    else
                        _GSM__SEC_VAL="${crdPwd}"
                    fi
                    {
                        if ((gsmSecFlagRef)); then
                            gsm-cli "$(cat - 0<<scrEOF
python3 main.py update \
    -c ${_GSM__SEC_COL@Q} \
    --from-literal "\${_GSM__SEC_VAL}" \
    ${gsmSecItemRef@Q}
scrEOF
                            )"
                        else
                            gsm-cli "$(cat - 0<<scrEOF
python3 main.py create \
    -c ${_GSM__SEC_COL@Q} \
    --from-literal "\${_GSM__SEC_VAL}" \
    ${gsmSecItemRef@Q} 0<<'ansEOF'
None
None
None
ansEOF
scrEOF
                            )"
                        fi
                    } 1> /dev/null || {
                        echo \
                            'Failed to create or update GSM Secret'\
                            "\`${gsmSecItemRef}\` in Collection \`${_GSM__SEC_COL}\`."\
                            1>&2
                        exit 1
                    }
                done
                ;;
            esac
        true )

#       # Update HashiCorp Vault.
#       [ -z "${_VAULT_MOUNT}" ] || [ -z "${_VAULT_KEY_PATH}" ] || [ \
#           -z "${_VAULT_KEY_USR}" ] || [ -z "${_VAULT_KEY_PWD}" \
#       ] || ( set +x
#           typeset vaultData=
#
#           vault token lookup &> /dev/null || {
#               echo 'Logging in to HashiCorp Vault...'
#               vault login 1> /dev/null
#           } || {
#               echo "You may NOT have access to HashiCorp Vault at \`${VAULT_ADDR}\`." 1>&2
#               exit 1
#           }
#           vaultData="$(vault kv get -mount="${_VAULT_MOUNT}" -format=json "${_VAULT_KEY_PATH}")" || {
#               echo \
#                   'You do NOT have access to HashiCorp Vault Secret'\
#                   "\`${_VAULT_MOUNT}/${_VAULT_KEY_PATH}\` at \`${VAULT_ADDR}\`."\
#                   1>&2
#               exit 1
#           }
#
#           case ${_AWS__OS__ACTION} in
#             (-1)
#               {
#                   jq -r \
#                       --arg ku "${_VAULT_KEY_USR}" \
#                       --arg kp "${_VAULT_KEY_PWD}" \
#                       '.data.data | del(.[$ku], .[$kp])' \
#                   0<<<"${vaultData}" |
#                   vault kv put -mount="${_VAULT_MOUNT}" "${_VAULT_KEY_PATH}" - 1> /dev/null
#               } || true   # Ignore error (may not have delete permission).
#               ;;
#             (1)
#               [ "$(jq -cr \
#                       --arg ku "${_VAULT_KEY_USR}" \
#                       --arg kp "${_VAULT_KEY_PWD}" \
#                       '
#                           if . then {
#                               u: (.data.data[$ku] // ""),
#                               p: (.data.data[$kp] // "")
#                           } else {u: "", p: ""} end
#                       ' \
#               0<<<"${vaultData}")" = "$(
#                   jq -cnr \
#                       --arg ku "${_AWS__OS__CRD_USR}" \
#                       --arg kp "${crdPwd}" \
#                       '{u: $ku, p: $kp}'
#               )" ] || {
#                   vault kv destroy -mount="${_VAULT_MOUNT}" -versions="$(
#                       jq -r '.data.metadata.version' 0<<<"${vaultData}"
#                   )" "${_VAULT_KEY_PATH}" &> /dev/null || true    # Ignore error (may not have delete permission).
#                   {
#                       jq -r \
#                           --arg ku "${_VAULT_KEY_USR}" \
#                           --arg vu "${_AWS__OS__CRD_USR}" \
#                           --arg kp "${_VAULT_KEY_PWD}" \
#                           --arg vp "${crdPwd}" \
#                           '.data.data | .[$ku]=$vu | .[$kp]=$vp' \
#                       0<<<"${vaultData}" |
#                       vault kv put -mount="${_VAULT_MOUNT}" "${_VAULT_KEY_PATH}" - 1> /dev/null
#                   } || {
#                       echo \
#                           'You do NOT have R/W access to HashiCorp Vault secret'\
#                           "\`${_VAULT_MOUNT}/${_VAULT_KEY_PATH}\`."\
#                           1>&2
#                       exit 1
#                   }
#               }
#               ;;
#           esac
#       true )

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Managing SSO User</summary>

```shell
__SHELL=0 \
    _AWS__OS__ACTION=1 \
    _AWS__OS__FQDN='...osFQDN...' \
    _AWS__OS__USR_EML='...osUsrEml...' \
    _AWS__OS__ROLE_NAME='...osRoleName...' \
    _AWS__COG__IDP_NAME='...cogIdPname...' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=admin \
   x_AWS__SES_TO=3600 \
    AWS_REGION='...awsRegion...' \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        {
            ((_AWS__RESET_PROFILE)) && {
                # Clean up the AWS CLI profile.
                sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
            }
            klist -s || kinit
            aws-saml.py \
                --region "${AWS_REGION}" \
                --target-profile "${_AWS__PROFILE}" \
                --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
            function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
            export -f aws
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset cogUsrPoolName="cog--${_AWS__COG__IDP_NAME}--up"
        typeset cogUsrPoolID= crdUsr= rolesMap= e= usrEml=
        typeset -a ssoUsrLst=()

        case ${_AWS__OS__ACTION} in (-1|0|1);; (*)false;; esac

        function awscurl () {
            command awscurl \
                --profile "${_AWS__PROFILE}" \
                --region "${AWS_REGION}" \
                --service es \
                "$@"
        }

        cogUsrPoolID="$(
            typeset _page= _cur= _id= _nextTkn=
            while true; do
                _page="$(
                    aws cognito-idp list-user-pools \
                        --max-results 60 \
                        ${_nextTkn:+--next-token "${_nextTkn}"} \
                        --output json
                )"
                _cur="$(jq -cr \
                    --arg name "${cogUsrPoolName}" \
                    '.UserPools[] | select(.Name == $name).Id' \
                0<<<"${_page}")"
                [ -n "${_cur}" ] && {
                    [ -n "${_id}" ] || [[ "${_cur}" == *$'\n'* ]] && {
                        : "ERROR: Multiple User Pools: ${cogUsrPoolName}"
                        exit 1
                    }
                    _id="${_cur}"
                }
                _nextTkn="$(jq -cr '(.NextToken // empty)' 0<<<"${_page}")"
                [ -z "${_nextTkn}" ] && break
            done
            [ -n "${_id}" ] || { : "ERROR: User Pool not found: ${cogUsrPoolName}"; exit 1; }
            echo "${_id}"
        )"
        case ${_AWS__OS__ACTION} in
          (-1|1)
            crdUsr="$(
                aws cognito-idp list-users \
                    --user-pool-id "${cogUsrPoolID}" \
                    --filter "email = \"${_AWS__OS__USR_EML}\"" \
                    --output text \
                    --query 'Users[0].Username'
            )"; [ "${crdUsr}" != "None" ]
            crdUsr="Cognito/${cogUsrPoolID}/${crdUsr}"
            ssoUsrLst=("${crdUsr}:${_AWS__OS__USR_EML}")
            ;;
          (0)
            while IFS= read -r e; do
                [ -z "${e}" ] || ssoUsrLst+=("${e}")
            done 0< <(
                aws cognito-idp list-users \
                    --user-pool-id "${cogUsrPoolID}" \
                    --output json |
                jq -r \
                    --arg p "${cogUsrPoolID}" \
                    '
                        .Users[] |
                        "Cognito/\($p)/\(.Username):\(
                            (
                                .Attributes[] |
                                select(.Name == "email")
                            ).Value // ""
                        )"
                    '
            )
            ;;
        esac

        case ${_AWS__OS__ACTION} in
          (-1)
            # Remove Role.
            awscurl -X PUT \
                -H 'Content-Type: application/json' \
                -d "$(jq -c \
                    --arg usr "${crdUsr}" \
                    --arg role "${_AWS__OS__ROLE_NAME}" \
                    '{
                        backend_roles: (.[$role].backend_roles // []),
                        users: ((.[$role].users // []) | map(select(. != $usr)))
                    }' \
                0< <(
                    awscurl -X GET \
                        "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${_AWS__OS__ROLE_NAME}" \
                        2> /dev/null ||
                    echo 'null'
                ))" \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${_AWS__OS__ROLE_NAME}"
            ;;
          (1)
            # Assign Role.
            awscurl -X PUT \
                -H 'Content-Type: application/json' \
                -d "$(jq -c \
                    --arg usr "${crdUsr}" \
                    --arg role "${_AWS__OS__ROLE_NAME}" \
                    '{
                        backend_roles: (.[$role].backend_roles // []),
                        users: (((.[$role].users // []) + [$usr]) | unique)
                    }' \
                0< <(
                    awscurl -X GET \
                        "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${_AWS__OS__ROLE_NAME}" \
                        2> /dev/null ||
                    echo 'null'
                ))" \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping/${_AWS__OS__ROLE_NAME}"
            ;;
        esac

        # Show SSO Users and assigned Roles.
        rolesMap="$(
            awscurl -X GET \
                "https://${_AWS__OS__FQDN}/_plugins/_security/api/rolesmapping"
        )"
        for e in "${ssoUsrLst[@]}"; do
            [ -z "${usrEml}" ] || printf '\n'
            crdUsr="${e%:*}"
            usrEml="${e#*:}"
            echo "${crdUsr}: ${usrEml}"
            {
                jq -r \
                    --arg usr "${crdUsr}" \
                    '["Roles:"] + [
                        to_entries[] |
                        select(.value.users | contains([$usr])) |
                        "    \(.key)"
                    ] | .[]' \
                0<<<"${rolesMap}"
            }
        done

        true
cmdEOF
    )"; echo $?
```
</details>


## Removal
<details><summary>Removing Cognito User Pool App. Client</summary>

 1. Delete the AWS Cognito User Pool App. Client.
    Run [Cognito.md - User Pool - User Pool App. Client](Cognito.md#setup) with:
    | Variable                  | Value                                             |
    |---------------------------|---------------------------------------------------|
    | `_AWS__COG__ACTION`       | `-1`                                              |
    | `_AWS__COG__CLIENT_NAME`  | `AmazonOpenSearchService-<osClientSfx>`           |
</details>
<details><summary>Removing OpenSearch Domain</summary>

```shell
__SHELL=0 \
    _AWS__OS__DOM_NAME='...osDomName...' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    AWS_REGION='...awsRegion...' \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        {
            ((_AWS__RESET_PROFILE)) && {
                # Clean up the AWS CLI profile.
                sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
            }
            klist -s || kinit
            aws-saml.py \
                --region "${AWS_REGION}" \
                --target-profile "${_AWS__PROFILE}" \
                --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX}" \
                ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
            function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
            export -f aws
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset -i wInt=0 wMax=0

        # Delete OpenSearch Domain.
        {
            aws opensearch describe-domain \
                --domain-name "${_AWS__OS__DOM_NAME}" \
            &> /dev/null &&
            aws opensearch delete-domain \
                --domain-name "${_AWS__OS__DOM_NAME}" \
                --no-cli-pager
        }

        # Monitor OpenSearch Domain deletion.
        (   # Isolate `SECONDS` reset.
            SECONDS=0 wInt=60 wMax=1800     # 30 Min. Max.
            # Domain deletion.
            while ((SECONDS < wMax)); do
                aws opensearch describe-domain \
                    --domain-name "${_AWS__OS__DOM_NAME}" \
                    &> /dev/null && sleep ${wInt} || break
                echo "Waited ${SECONDS}/${wMax} sec.: "\
'Deleting OpenSearch Domain...' 1>&2
            done
            ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'OpenSearch Domain deletion.' 1>&2; exit 2; }
        )

        true
cmdEOF
    )"; echo $?
```
</details>

**Post-requisites:**
  - Run [Cognito.md - IAM Roles - IAM App. Servicing Role](Cognito.md#setup) with:
    | Variable                      | Value                                     |
    |-------------------------------|-------------------------------------------|
    | `_AWS__COG__ACTION`           | `-1`                                      |
    | `_AWS__COG__APP_PRINCIPAL`    | `es.amazonaws.com`                        |
    | `_AWS__COG__APP_POL_NAME`     | `AmazonOpenSearchServiceCognitoAccess`    |
  - Run [Cognito.md - Removal](Cognito.md#removal) to tear down remaining Cognito resources.

# AWS Cognito
```
                  ┌────────────────────────────────────────────────────────────────────┐
                  │  User Pool (cog--{IDP_NAME}--up)                                   │
  ┌────────────┐  │    Domain: {DOMAIN_PFX}.auth.{REGION}.amazoncognito.com            │
  │  External  │◄─┤    Identity Provider: {IDP_TYPE} (e.g. Google OIDC)                │
  │    IdP     │  │                                                                    │
  └────────────┘  │  App. Clients (1 per WebApp):                                      │
                  │    ┌──────────────────────────────────────────────────────────┐    │
                  │    │  cog--{IDP_NAME}--client--{APP}  (CallBack/LogOut URLs)  │    │
                  │    └──────────────────────────┬───────────────────────────────┘    │
                  └───────────────────────────────┼────────────────────────────────────┘
                                                  │ ProviderName + ClientId
                  ┌───────────────────────────────┼────────────────────────────────────┐
                  │  Identity Pool (cog--{IDP_NAME}--ip[--{ID_POOL_SFX}])              │
                  │                               │                                    │
                  │    ┌──────────────────────────┴────────────────────────────┐       │
                  │    │  CognitoIdentityProviders  (1 entry per App. Client)  │       │
                  │    └───────────────────────────────────────────────────────┘       │
                  │                                                                    │
                  │  Auth   ─► cog--{IDP_NAME}--role--auth    (no permissions)         │
                  │  UnAuth ─► cog--{IDP_NAME}--role--un-auth (deny-all)               │
                  └────────────────────────────────────────────────────────────────────┘

  ┌────────────────────────────────────────────────────────────────────────────────────┐
  │  cog--{IDP_NAME}--role--auth                                                       │
  │    Trust:       cognito-identity.amazonaws.com, aud = Identity Pool ID             │
  │    Permissions: none — WebApp grants access via its own FGAC                       │
  ├────────────────────────────────────────────────────────────────────────────────────┤
  │  cog--{IDP_NAME}--role--un-auth                                                    │
  │    Trust:       cognito-identity.amazonaws.com, aud = Identity Pool ID             │
  │    Permissions: deny-all                                                           │
  ├────────────────────────────────────────────────────────────────────────────────────┤
  │  cog--{IDP_NAME}--role--app  (App. Servicing Role - shared across WebApps)         │
  │    Trust:       es.amazonaws.com, grafana.amazonaws.com, ...                       │
  │    Permissions: AmazonOpenSearchServiceCognitoAccess, ...                          │
  └────────────────────────────────────────────────────────────────────────────────────┘

  SSO Flow:
  User ─► WebApp ─► Cognito Hosted UI ─► External IdP Login
                 ◄─ Identity Pool assigns Auth Role ◄─ Cognito validates JWT
```

## Setup
<details><summary>Cognito User Pool and IdP</summary>

**Pre-requisites:**
  - **(GCP Console):** Configure the GCP OAuth2 Client in the [Google Cloud Console](https://console.cloud.google.com/apis/credentials):
      - Add `amazoncognito.com` to the OAuth Consent Screen **Authorized Domains**.
      - Add the **Authorized Redirect URI**: `https://<lowercase(_AWS__COG__IDP_NAME)>.auth.<AWS_REGION>.amazoncognito.com/oauth2/idpresponse`
```shell
__SHELL=0 \
    _AWS__COG__IDP_NAME='...cogIdPname...' \
    _AWS__COG__IDP_TYPE='...cogIdPtype...' \
    _AWS__COG__IDP_SCOPES='...cogIdPscopes...' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    _BW__NOTE_SUB_FLD='oAuth.OpenSearch' \
    _BW__NOTE_NAME='...bwNoteName...' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
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
        {
            typeset __shOpt="$(shopt -po xtrace)"; set +x
            [ -n "${BW_SESSION}" ] && bw sync || {
                echo 'You do NOT have an active and sync:ed BitWarden Session!!!' 1>&2
                exit 1
            }
            eval "$(
                typeset bwData=
                bwData="$(bw get item "${_BW__NOTE_NAME}")" || {
                    echo "You may NOT have access to BitWarden Note \`${_BW__NOTE_NAME}\`." 1>&2
                    echo false; exit 1
                }
                jq -r \
                    --arg fn__c "${_BW__NOTE_SUB_FLD}" \
                    '
                        .fields[]? | select(.name == $fn__c).value | fromjson |
                        .web | "
                            export _IDP__CLIENT_ID=\(.client_id | @sh) _IDP__CLIENT_SECRET=\(.client_secret | @sh)
                        "
                    ' \
                0<<<"${bwData}"
            )"
            eval "${__shOpt}"; unset __shOpt
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset cogUsrPoolName="cog--${_AWS__COG__IDP_NAME}--up"
        typeset cogUsrPoolDom="${_AWS__COG__IDP_NAME,,}"
        typeset cogUsrPoolID=

        # Create User Pool.
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
            [ -n "${_id}" ] && { echo "${_id}"; exit 0; }
            aws cognito-idp create-user-pool \
                --pool-name "${cogUsrPoolName}" \
                --auto-verified-attributes email \
                --username-attributes email \
                --username-configuration CaseSensitive=false \
                --output text \
                --query 'UserPool.Id'
        )"

        # Create User Pool Domain.
        if [ "$(
            aws cognito-idp describe-user-pool-domain \
                --domain "${cogUsrPoolDom}" \
                --output text \
                --query 'DomainDescription.UserPoolId'
        )" = None ]; then
            aws cognito-idp create-user-pool-domain \
                --domain "${cogUsrPoolDom}" \
                --user-pool-id "${cogUsrPoolID}" \
                --no-cli-pager
        fi

        # Create Identity Provider.
        ( set +x
            aws cognito-idp describe-identity-provider \
                --user-pool-id "${cogUsrPoolID}" \
                --provider-name "${_AWS__COG__IDP_TYPE}" \
                &> /dev/null ||
            aws cognito-idp create-identity-provider \
                --cli-input-json "$(
                    jq -cn \
                        --arg upID "${cogUsrPoolID}" \
                        --arg idpType "${_AWS__COG__IDP_TYPE}" \
                        --arg idpClientID "${_IDP__CLIENT_ID}" \
                        --arg idpClientCred "${_IDP__CLIENT_SECRET}" \
                        --arg idpClientScopes "${_AWS__COG__IDP_SCOPES}" \
                        '{
                            UserPoolId: $upID,
                            ProviderName: $idpType,
                            ProviderType: $idpType,
                            ProviderDetails: {
                                client_id: $idpClientID,
                                client_secret: $idpClientCred,
                                authorize_scopes: $idpClientScopes
                            },
                            AttributeMapping: {email: "email", username: "sub"}
                        }'
                )" 1> /dev/null
        true )

        cat - 0<<txtEOF 1>&2
--------------------------------------------------------------------------------
Cognito User Pool created:
    Pool ID:    ${cogUsrPoolID}
    Domain:     https://${cogUsrPoolDom}.auth.${AWS_REGION}.amazoncognito.com
--------------------------------------------------------------------------------
txtEOF

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>User Pool App. Client</summary>

```shell
__SHELL=0 \
    _AWS__COG__ACTION=1 \
    _AWS__COG__IDP_NAME='...cogIdPname...' \
    _AWS__COG__IDP_TYPE='...cogIdPtype...' \
    _AWS__COG__APP_NAME='...cogAppName...' \
    _AWS__COG__CLIENT_NAME="cog--${_AWS__COG__IDP_NAME}--client--${_AWS__COG__APP_NAME}" \
    _AWS__COG__CALLBACK_URLS='...appCallBackURL...' \
    _AWS__COG__LOGOUT_URLS='...appLogOutURL...' \
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
        typeset cogUsrPoolID= cogClientID=

        case ${_AWS__COG__ACTION} in (-1|0|1);; (*)false;; esac

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
            echo "${_id}"
        )"
        cogClientID="$(
            cogClientID="$(
                aws cognito-idp list-user-pool-clients \
                    --user-pool-id "${cogUsrPoolID}" \
                    --output text \
                    --query "UserPoolClients[?
                        (ClientName == '${_AWS__COG__CLIENT_NAME}')
                    ].ClientId"
            )"
            [ -n "${cogClientID}" ] && {
                [[ "${cogClientID}" == *$'\t'* ]] && {
                    : "ERROR: Multiple App Clients: ${_AWS__COG__CLIENT_NAME}"
                    exit 1
                }
                case ${_AWS__COG__ACTION} in
                  (1)   { echo "${cogClientID}"; exit 0; };;
                esac
            } || {
                case ${_AWS__COG__ACTION} in
                  (-1)  exit 0;;
                  (0)
                    : "ERROR: Not found App Clients: ${_AWS__COG__CLIENT_NAME}"
                    exit 1
                    ;;
                esac
            }
            case ${_AWS__COG__ACTION} in
              (-1)
                # Deleting App. Client.
                aws cognito-idp delete-user-pool-client \
                    --user-pool-id "${cogUsrPoolID}" \
                    --client-id "${cogClientID}" \
                    --no-cli-pager
                echo "${cogClientID}"
                ;;
              (0)
                # Updating App. Client.
                aws cognito-idp update-user-pool-client \
                    --user-pool-id "${cogUsrPoolID}" \
                    --client-id "${cogClientID}" \
                    --supported-identity-providers "${_AWS__COG__IDP_TYPE}" \
                    --callback-urls "${_AWS__COG__CALLBACK_URLS}" \
                    --logout-urls "${_AWS__COG__LOGOUT_URLS}" \
                    --allowed-o-auth-flows code \
                    --allowed-o-auth-scopes email openid profile \
                    --allowed-o-auth-flows-user-pool-client \
                    --output text \
                    --query 'UserPoolClient.ClientId'
                ;;
              (1)
                # Creating App. Client.
                aws cognito-idp create-user-pool-client \
                    --user-pool-id "${cogUsrPoolID}" \
                    --client-name "${_AWS__COG__CLIENT_NAME}" \
                    --supported-identity-providers "${_AWS__COG__IDP_TYPE}" \
                    --output text \
                    --query 'UserPoolClient.ClientId'
                ;;
            esac
        )"

        cat - 0<<txtEOF 1>&2
--------------------------------------------------------------------------------
Cognito App. Client $(
    case ${_AWS__COG__ACTION} in
      (-1)  echo deleted;;
      (0)   echo updated;;
      (1)   echo created;;
    esac
):
    Client Name:    ${_AWS__COG__CLIENT_NAME}
    Client ID:      ${cogClientID}
--------------------------------------------------------------------------------
txtEOF

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Cognito Identity Pool</summary>

```shell
__SHELL=0 \
    _AWS__COG__ACTION=1 \
    _AWS__COG__IDP_NAME='...cogIdPname...' \
    _AWS__COG__APP_NAME='...cogAppName...' \
    _AWS__COG__CLIENT_NAME="cog--${_AWS__COG__IDP_NAME}--client--${_AWS__COG__APP_NAME}" \
    _AWS__COG__ID_POOL_SFX='' \
    _AWS__COG__ALLOW_UNAUTH=1 \
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
        typeset cogIdPoolName="cog--${_AWS__COG__IDP_NAME}--ip${_AWS__COG__ID_POOL_SFX:+--${_AWS__COG__ID_POOL_SFX}}"
        typeset cogProvider="cognito-idp.${AWS_REGION}.amazonaws.com/"
        typeset cogUsrPoolID= cogClientID= cogIdPoolID=

        case ${_AWS__COG__ACTION} in (-1|0|1);; (*)false;; esac

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
            echo "${_id}"
        )"
        cogProvider+="${cogUsrPoolID}"
        cogClientID="$(
            cogClientID="$(
                aws cognito-idp list-user-pool-clients \
                    --user-pool-id "${cogUsrPoolID}" \
                    --output text \
                    --query "UserPoolClients[?
                        (ClientName == '${_AWS__COG__CLIENT_NAME}')
                    ].ClientId"
            )"
            ((_AWS__COG__ACTION)) || exit 0
            [ -n "${cogClientID}" ] && {
                [[ "${cogClientID}" == *$'\t'* ]] && {
                    : "ERROR: Multiple App Clients: ${_AWS__COG__CLIENT_NAME}"
                    exit 1
                }
                { echo "${cogClientID}"; exit 0; }
            }
        )"

        # Create Identity Pool.
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
            [ -n "${_id}" ] && { echo "${_id}"; exit 0; }
            aws cognito-identity create-identity-pool \
                --identity-pool-name "${cogIdPoolName}" \
                --"$(
                    ((_AWS__COG__ALLOW_UNAUTH)) || echo -n no-
                )"allow-unauthenticated-identities \
                --output text \
                --query 'IdentityPoolId'
        )"
        # Update Identity Pool Providers.
        ((_AWS__COG__ACTION)) && aws cognito-identity update-identity-pool \
            --cli-input-json "$(
                jq -cn \
                    --argjson idPool "$(
                        aws cognito-identity describe-identity-pool \
                            --identity-pool-id "${cogIdPoolID}" \
                            --output json
                    )" \
                    --arg provider "${cogProvider}" \
                    --arg clientId "${cogClientID}" \
                    --argjson action "${_AWS__COG__ACTION}" \
                    '
                        $idPool |
                        del(.CreationDate, .LastModifiedDate) |
                        .CognitoIdentityProviders|=(
                            (. // []) |
                            map(select(.ClientId != $clientId)) + (
                                if ($action == 1) then [{
                                    ProviderName: $provider,
                                    ClientId: $clientId,
                                    ServerSideTokenCheck: false
                                }] else [] end
                            )
                        )
                    '
            )" \
            --no-cli-pager

        cat - 0<<txtEOF 1>&2
--------------------------------------------------------------------------------
Cognito Identity Pool Provider Client association $(
    case ${_AWS__COG__ACTION} in
      (-1)  echo 'removed';;
      (0)   echo 'skipped';;
      (1)   echo 'added';;
    esac
):
    Identity Pool ID:   ${cogIdPoolID}
    Provider:           ${cogProvider}
    Client ID:          ${cogClientID}
--------------------------------------------------------------------------------
txtEOF

        true
cmdEOF
    )"; echo $?
```
**Notes:**
  - The `AllowUnauthenticatedIdentities` is required by AWS for OpenSearch-Cognito integration.
  - The Un-Authenticated IAM Role (created in the next section) has zero permissions.
</details>
<details><summary>IAM Auth/Un-Auth Roles</summary>

```shell
__SHELL=0 \
    _AWS__COG__ACTION=1 \
    _AWS__COG__IDP_NAME='...cogIdPname...' \
    _AWS__COG__APP_NAME='...cogAppName...' \
    _AWS__COG__ID_POOL_SFX='' \
    _AWS__COG__APP_AUTH_POL_PERM='("...iamPolAct...|...iamPolRes")' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=admin \
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

        typeset cogIdPoolName="cog--${_AWS__COG__IDP_NAME}--ip${_AWS__COG__ID_POOL_SFX:+--${_AWS__COG__ID_POOL_SFX}}"
        typeset cogIAMroleAuth="cog--${_AWS__COG__IDP_NAME}--role--auth"
        typeset cogIAMroleUnAuth="cog--${_AWS__COG__IDP_NAME}--role--un-auth"
        typeset cogIdPoolID=
        typeset addRolePol= polName= cogIAMroleAuthARN= cogIAMroleUnAuthARN=
        typeset -a cogIAMpolAuth=${_AWS__COG__APP_AUTH_POL_PERM}

        case ${_AWS__COG__ACTION} in (-1|1);; (*)false;; esac

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
            echo "${_id}"
        )"
        # Create Authenticated Role (for SSO users via Cognito).
        #   Least-privilege:
        #       No permissions by default.
        #       Consuming WebApp grants access via its own FGAC (Fine-Grained
        #       Access Control).
        addRolePol="$(
            jq -cn \
                --arg ipID "${cogIdPoolID}" \
                '{
                    Effect: "Allow",
                    Principal: {Federated: "cognito-identity.amazonaws.com"},
                    Action: "sts:AssumeRoleWithWebIdentity",
                    Condition: {
                        StringEquals: {
                            "cognito-identity.amazonaws.com:aud": $ipID
                        },
                        "ForAnyValue:StringLike": {
                            "cognito-identity.amazonaws.com:amr": "authenticated"
                        }
                    }
                }'
        )"
        cogIAMroleAuthARN="$(
            aws iam get-role \
                --role-name "${cogIAMroleAuth}" \
                --output text \
                --query 'Role.Arn' \
                2> /dev/null ||
            aws iam create-role \
                --role-name "${cogIAMroleAuth}" \
                --assume-role-policy-document "$(
                    jq -cn --argjson addRolePol "${addRolePol}" '
                        {"Version": "2012-10-17", "Statement": [$addRolePol]}
                    '
                )" \
                --tags "$(
                    jq -cn \
                        --arg svc "cog--${_AWS__COG__IDP_NAME}" \
                        '[{Key: "Svc", Value: $svc}]'
                )" \
                --output text \
                --query 'Role.Arn'
        )"
        # Update Trust Policy.
        aws iam update-assume-role-policy \
            --role-name "${cogIAMroleAuth}" \
            --policy-document "$(
                jq -cn \
                    --argjson rolePol "$(
                        aws iam get-role \
                            --role-name "${cogIAMroleAuth}" \
                            --output json \
                            --query 'Role.AssumeRolePolicyDocument'
                    )" \
                    --arg ipID "${cogIdPoolID}" \
                    --argjson action "${_AWS__COG__ACTION}" \
                    --argjson addRolePol "${addRolePol}" \
                    '
                        $rolePol |
                        .Statement|=(map(select(
                            (.Condition.StringEquals."cognito-identity.amazonaws.com:aud" // "") != $ipID
                        )) + (if ($action == 1) then [$addRolePol] else [] end))
                    '
            )" \
            --no-cli-pager
        # Inline Permission Policy.
        ((${#cogIAMpolAuth[@]})) && {
            polName="${cogIAMroleAuth}--pol--app--auth--${_AWS__COG__APP_NAME}"
            case ${_AWS__COG__ACTION} in
              (-1)
                {
                    aws iam get-role-policy \
                        --role-name "${cogIAMroleAuth}" \
                        --policy-name "${polName}" \
                        &> /dev/null &&
                    aws iam delete-role-policy \
                        --role-name "${cogIAMroleAuth}" \
                        --policy-name "${polName}" \
                        --no-cli-pager
                }
                ;;
              (1)
                aws iam put-role-policy \
                    --role-name "${cogIAMroleAuth}" \
                    --policy-name "${polName}" \
                    --policy-document "$(
                        printf '%s\n' "${cogIAMpolAuth[@]}" |
                        jq -cRs '
                            split("\n") |
                            map(
                                select(length > 0) |
                                split("|") |
                                {Effect: "Allow", Action: .[0], Resource: .[1]}
                            ) |
                            {Version: "2012-10-17", Statement: .}
                        '
                    )" \
                    --no-cli-pager
                ;;
            esac
        }

        # Create Un-Authenticated Role.
        addRolePol="$(
            jq -cn --argjson addRolePol "${addRolePol}" '
                $addRolePol | .Condition."ForAnyValue:StringLike"|=(
                    ."cognito-identity.amazonaws.com:amr"="unauthenticated"
                )
            '
        )"
        cogIAMroleUnAuthARN="$(
            aws iam get-role \
                --role-name "${cogIAMroleUnAuth}" \
                --output text \
                --query 'Role.Arn' \
                2> /dev/null ||
            aws iam create-role \
                --role-name "${cogIAMroleUnAuth}" \
                --assume-role-policy-document "$(
                    jq -cn --argjson addRolePol "${addRolePol}" '
                        {"Version": "2012-10-17", "Statement": [$addRolePol]}
                    '
                )" \
                --tags "$(
                    jq -cn \
                        --arg svc "cog--${_AWS__COG__IDP_NAME}" \
                        '[{Key: "Svc", Value: $svc}]'
                )" \
                --output text \
                --query 'Role.Arn'
        )"
        # Update Trust Policy.
        aws iam update-assume-role-policy \
            --role-name "${cogIAMroleUnAuth}" \
            --policy-document "$(
                jq -cn \
                    --argjson rolePol "$(
                        aws iam get-role \
                            --role-name "${cogIAMroleUnAuth}" \
                            --output json \
                            --query 'Role.AssumeRolePolicyDocument'
                    )" \
                    --arg ipID "${cogIdPoolID}" \
                    --argjson action "${_AWS__COG__ACTION}" \
                    --argjson addRolePol "${addRolePol}" \
                    '
                        $rolePol |
                        .Statement|=(map(select(
                            (.Condition.StringEquals."cognito-identity.amazonaws.com:aud" // "") != $ipID
                        )) + (if ($action == 1) then [$addRolePol] else [] end))
                    '
            )" \
            --no-cli-pager
        # Inline Permission Policy.
        polName="${cogIAMroleUnAuth}--pol--deny-all"
        case ${_AWS__COG__ACTION} in
          (-1)
            {
                aws iam get-role-policy \
                    --role-name "${cogIAMroleUnAuth}" \
                    --policy-name "${polName}" \
                    &> /dev/null &&
                aws iam delete-role-policy \
                    --role-name "${cogIAMroleUnAuth}" \
                    --policy-name "${polName}" \
                    --no-cli-pager
            }
            ;;
          (1)
            aws iam put-role-policy \
                --role-name "${cogIAMroleUnAuth}" \
                --policy-name "${polName}" \
                --policy-document "$(jq -cn '{
                    Version: "2012-10-17",
                    Statement: [{Effect: "Deny", Action: "*", Resource: "*"}]
                }')" \
                --no-cli-pager
            ;;
        esac

        # Assign IAM Roles to Identity Pool.
        aws cognito-identity set-identity-pool-roles \
            --identity-pool-id "${cogIdPoolID}" \
            --roles "$(
                jq -cn \
                    --arg auth "${cogIAMroleAuthARN}" \
                    --arg unauth "${cogIAMroleUnAuthARN}" \
                    '{authenticated: $auth, unauthenticated: $unauth}'
            )" \
            --no-cli-pager

        cat - 0<<txtEOF 1>&2
--------------------------------------------------------------------------------
Cognito IAM Auth/Un-Auth Roles Trust Relation $(
    case ${_AWS__COG__ACTION} in
      (-1)  echo 'removed';;
      (1)   echo 'added';;
    esac
):
    Auth Role ARN:      ${cogIAMroleAuthARN}
    Un-Auth Role ARN:   ${cogIAMroleUnAuthARN}
--------------------------------------------------------------------------------
txtEOF

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>IAM App. Servicing Role</summary>

IAM Role assumed by the App. (AWS Managed Service) to manage Cognito Auth. on the App.'s behalf.
Shared across Apps. Re-run with a different `_AWS__COG__APP_POL_NAME` and/or `_AWS__COG__APP_PRINCIPAL` to add another App. (existing trusts are preserved).
```shell
__SHELL=0 \
    _AWS__COG__ACTION=1 \
    _AWS__COG__IDP_NAME='...cogIdPname...' \
    _AWS__COG__APP_POL_NAME='...appPolName...' \
    _AWS__COG__APP_PRINCIPAL='...appPrincipal...' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=admin \
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

        typeset cogIAMroleApp="cog--${_AWS__COG__IDP_NAME}--role--app"
        typeset cogIAMpolAppARN= addRolePol= cogIAMroleAppARN=

        case ${_AWS__COG__ACTION} in (-1|1);; (*)false;; esac

        cogIAMpolAppARN="$(
            aws iam list-policies \
                --output text \
                --query "Policies[?
                    (PolicyName == '${_AWS__COG__APP_POL_NAME}')
                ].Arn"
        )"
        addRolePol="$(
            jq -cn \
                --arg app "${_AWS__COG__APP_PRINCIPAL}" \
                '{
                    Effect: "Allow",
                    Principal: {Service: $app},
                    Action: "sts:AssumeRole"
                }'
        )"

        # Create App. Servicing Role.
        cogIAMroleAppARN="$(
            aws iam get-role \
                --role-name "${cogIAMroleApp}" \
                --output text \
                --query 'Role.Arn' \
                2> /dev/null ||
            aws iam create-role \
                --role-name "${cogIAMroleApp}" \
                --assume-role-policy-document "$(
                    jq -cn --argjson addRolePol "${addRolePol}" '
                        {"Version": "2012-10-17", "Statement": [$addRolePol]}
                    '
                )" \
                --tags "$(
                    jq -cn \
                        --arg svc "cog--${_AWS__COG__IDP_NAME}" \
                        '[{Key: "Svc", Value: $svc}]'
                )" \
                --output text \
                --query 'Role.Arn'
        )"
        # Update Trust Policy.
        aws iam update-assume-role-policy \
            --role-name "${cogIAMroleApp}" \
            --policy-document "$(
                jq -cn \
                    --argjson rolePol "$(
                        aws iam get-role \
                            --role-name "${cogIAMroleApp}" \
                            --output json \
                            --query 'Role.AssumeRolePolicyDocument'
                    )" \
                    --arg app "${_AWS__COG__APP_PRINCIPAL}" \
                    --argjson action "${_AWS__COG__ACTION}" \
                    --argjson addRolePol "${addRolePol}" \
                    '
                        $rolePol |
                        .Statement|=(map(select(
                            (.Principal.Service // "") != $app
                        )) + (if ($action == 1) then [$addRolePol] else [] end))
                    '
            )" \
            --no-cli-pager
        # Managed Permission Policy.
        case ${_AWS__COG__ACTION} in
          (-1)
            aws iam detach-role-policy \
                --role-name "${cogIAMroleApp}" \
                --policy-arn "${cogIAMpolAppARN}" \
                --no-cli-pager
            ;;
          (1)
            aws iam attach-role-policy \
                --role-name "${cogIAMroleApp}" \
                --policy-arn "${cogIAMpolAppARN}" \
                --no-cli-pager
            ;;
        esac

        cat - 0<<txtEOF 1>&2
--------------------------------------------------------------------------------
Cognito IAM App. Servicing Role Trust Relation $(
    case ${_AWS__COG__ACTION} in
      (-1)  echo 'removed';;
      (1)   echo 'added';;
    esac
):
    Role ARN:   ${cogIAMroleAppARN}
    Principal:  ${_AWS__COG__APP_PRINCIPAL}
    Policy:     ${_AWS__COG__APP_POL_NAME}
--------------------------------------------------------------------------------
txtEOF

        true
cmdEOF
    )"; echo $?
```
</details>


## Removal
<details><summary>Cognito Identity Pool and IAM Roles</summary>

```shell
__SHELL=0 \
    _AWS__COG__IDP_NAME='...cogIdPname...' \
    _AWS__COG__ID_POOL_SFX='' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=admin \
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

        typeset cogIdPoolName="cog--${_AWS__COG__IDP_NAME}--ip${_AWS__COG__ID_POOL_SFX:+--${_AWS__COG__ID_POOL_SFX}}"
        typeset cogIAMroleApp="cog--${_AWS__COG__IDP_NAME}--role--app"
        typeset cogIAMroleUnAuth="cog--${_AWS__COG__IDP_NAME}--role--un-auth"
        typeset cogIAMroleAuth="cog--${_AWS__COG__IDP_NAME}--role--auth"
        typeset cogIdPoolID=

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
            echo "${_id}"
        )"

        # Delete Identity Pool.
        [ -n "${cogIdPoolID}" ] && {
            aws cognito-identity delete-identity-pool \
                --identity-pool-id "${cogIdPoolID}" \
                --no-cli-pager
        }

        # Delete IAM Roles.
        #   App. Servicing Role.
        {
            [ -n "$(
                aws iam list-attached-role-policies \
                    --role-name "${cogIAMroleApp}" \
                    --output text \
                    --query 'AttachedPolicies[].PolicyArn' \
                    2> /dev/null
            )" ] && {
                aws iam list-attached-role-policies \
                    --role-name "${cogIAMroleApp}" \
                    --output text \
                    --query 'AttachedPolicies[].PolicyArn' |
                while read -r _polARN; do
                    aws iam detach-role-policy \
                        --role-name "${cogIAMroleApp}" \
                        --policy-arn "${_polARN}" \
                        --no-cli-pager
                done
            }
        }
        {
            aws iam get-role \
                --role-name "${cogIAMroleApp}" \
                &> /dev/null &&
            aws iam delete-role \
                --role-name "${cogIAMroleApp}" \
                --no-cli-pager
        }
        #   Un-Auth Role.
        {
            aws iam get-role-policy \
                --role-name "${cogIAMroleUnAuth}" \
                --policy-name "${cogIAMroleUnAuth}--pol--deny-all" \
                &> /dev/null &&
            aws iam delete-role-policy \
                --role-name "${cogIAMroleUnAuth}" \
                --policy-name "${cogIAMroleUnAuth}--pol--deny-all" \
                --no-cli-pager
        }
        {
            aws iam get-role \
                --role-name "${cogIAMroleUnAuth}" \
                &> /dev/null &&
            aws iam delete-role \
                --role-name "${cogIAMroleUnAuth}" \
                --no-cli-pager
        }
        #   Auth Role (no inline policies, permissions granted via WebApp
        #   FGAC).
        {
            aws iam get-role \
                --role-name "${cogIAMroleAuth}" \
                &> /dev/null &&
            aws iam delete-role \
                --role-name "${cogIAMroleAuth}" \
                --no-cli-pager
        }

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Cognito User Pool and IdP</summary>

```shell
__SHELL=0 \
    _AWS__COG__IDP_NAME='...cogIdPname...' \
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
        typeset cogUsrPoolID=

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
            echo "${_id}"
        )"

        # Delete User Pool Domain and User Pool.
        [ -n "${cogUsrPoolID}" ] && {
            [ "$(
                aws cognito-idp describe-user-pool \
                    --user-pool-id "${cogUsrPoolID}" \
                    --output text \
                    --query 'UserPool.Domain'
            )" != "None" ] && {
                aws cognito-idp delete-user-pool-domain \
                    --user-pool-id "${cogUsrPoolID}" \
                    --domain "${_AWS__COG__IDP_NAME,,}" \
                    --no-cli-pager
            }
            aws cognito-idp delete-user-pool \
                --user-pool-id "${cogUsrPoolID}" \
                --no-cli-pager
        }

        true
cmdEOF
    )"; echo $?
```
</details>

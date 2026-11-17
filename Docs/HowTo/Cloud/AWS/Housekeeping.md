# AWS House Keeping
## Secret Management
### IAM Access Key
#### IAM Access Key Rotation
<details><summary>Rotating IAM Access Key</summary>

```shell
__SHELL=0 \
    _JOB__MIN_DAYS=3 \
    _AWS__SELF_PROV=1 \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=saml \
   x_AWS__SES_TO=3600 \
    _AWS__AIM_USR_NAME=u-ieng--ocp-installer \
    _BW__NOTE_NAME='...bwNoteName...' \
    _GSM__CTR_IMG='quay.io/openshift/ci-public:ci_secret-manager_latest' \
    _GSM__SEC_COL='...gsmSecCol...' \
   x_VAULT_MOUNT=kv \
   x_VAULT_KEY_SFX='...vaultKeySfx...' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    AWS_REGION=us-east-1 \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
   xVAULT_ADDR='https://vault.ci.openshift.org' \
    bash -uc "$(cat - 0<<'cmdEOF'
        {
            typeset __shOpt="$(shopt -po xtrace)"; set +x
            [ -n "${BW_SESSION}" ] && bw sync || {
                echo 'You do NOT have an active and sync:ed BitWarden Session!!!' 1>&2
                exit 1
            }
            typeset -x bwData="$(bw get item "${_BW__NOTE_NAME}")"
            [ -z "${bwData}" ] && {
                echo "You may NOT have access to BitWarden Note \`${_BW__NOTE_NAME}\`." 1>&2
                exit 1
            }
            eval "${__shOpt}"; unset __shOpt
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset e= keyDate=1970-01-01
        typeset +x bwData

        (
            eval "$(jq -r '.fields[]? | select(.name == "metadata.keyDate") | .value' 0<<<"${bwData}")"
            e="$(($(date -u +%s) - $(date -d "${keyDate}" +%s) + (6*60*60)))"   # Allow 6 h earlier as threshold.
            ((e < (_JOB__MIN_DAYS*24*60*60))) && echo "Do not need to generate new Access Key as it is only $(
                python3 -c 'import sys, datetime; print(datetime.timedelta(seconds=int(sys.argv[1])).days)' "${e}"
            ) days old."
        ) || {
            {
                typeset __shOpt="$(shopt -po xtrace)"; set +x
                # Bash parsing error for `[ ... != ... ]` expression, when
                #   there are several multi-lines nested command substitutions
                #   in an interactive session. Need to assign to var. first.
                typeset oldVal="$(jq -cr '
                    (.fields[]? | select(.name == "metadata.keyDate")).value
                ' 0<<<"${bwData}")"
                typeset newVal="$(jq -r '
                    (.fields[]? | select(.name == "metadata.keyDate")).value|=(
                        if (. | test(" # rwTest (0|1)$")) then
                            . | sub("(?<bit>\\d)$"; (
                                if (.bit == "1") then "0" else "1" end
                            ))
                        else
                            . + " # rwTest 0"
                        end
                    )
                ' 0<<<"${bwData}" | bw encode | bw edit item "$(
                    jq -cr '.id' 0<<<"${bwData}"
                )" | jq -cr '
                    (.fields[]? | select(.name == "metadata.keyDate")).value
                ')"
                { [ "${oldVal}" != "${newVal}" ] || {
                    echo "You do NOT have R/W access to BitWarden Note \`${_BW__NOTE_NAME}\`." 1>&2
                    exit 1
                }; } && bw sync 1> /dev/null && bwData="$(bw get item "${_BW__NOTE_NAME}")"
                eval "${__shOpt}"; unset __shOpt
            }

            # AWS Authentication.
            if ((_AWS__SELF_PROV)); then
                eval "$(jq -r '.notes' 0<<<"${bwData}")"
            else
                ((_AWS__RESET_PROFILE)) && {
                    # Clean up the AWS CLI profile.
                    sed -i "/^\\[profile ${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[profile ${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_CONFIG_FILE}"
                    sed -i "/^\\[${_AWS__PROFILE}\\]/,/^\\[/ {/^\\[${_AWS__PROFILE}\\]/{d;b};/^\\[/"\!"d}" "${AWS_SHARED_CREDENTIALS_FILE}"
                }
                klist -s || kinit
                aws-saml.py \
                    --region "${AWS_REGION}" \
                    --target-profile "${_AWS__PROFILE}" \
                    --target-role "${AWS_ACCOUNT_ID}-${_AWS__ROLE_NAME_SFX:=admin}" \
                    ${_AWS__SES_TO:+--session-duration "${_AWS__SES_TO}"}
                function aws () { command aws --profile "${_AWS__PROFILE}" "$@"; }
                export -f aws
            fi

            # Delete stale Access Keys.
            for e in $(
                aws iam list-access-keys --user-name "${_AWS__AIM_USR_NAME}" |
                jq -r \
                    --arg curKeyId "$(
                        eval "$(jq -r '.notes' 0<<<"${bwData}")"
                        echo "${AWS_ACCESS_KEY_ID}"
                    )" \
                    '.AccessKeyMetadata[] | select(.AccessKeyId != $curKeyId) | .AccessKeyId'
            ); do aws iam delete-access-key --user-name "${_AWS__AIM_USR_NAME}" --access-key-id "${e}"; done
            # Generate new Access Key and update BitWarden Note.
            {
                typeset __shOpt="$(shopt -po xtrace)"; set +x
                bwData="$(jq -r \
                    --arg n "$(
                        eval "$(
                            aws iam create-access-key --user-name "${_AWS__AIM_USR_NAME}" |
                            jq -r '.AccessKey | "
                                '"export AWS_ACCESS_KEY_ID='\\(.AccessKeyId)' AWS_SECRET_ACCESS_KEY='\\(.SecretAccessKey)'"'
                            "'
                        )"
                        typeset -p AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
                    )" \
                    --rawfile fv__m <( set +x
                        printf '%s' "$(
                            typeset keyDate="$(date -u +'%Y-%m-%d %H:%M:%S %Z')"
                            typeset -p keyDate
                        )"
                    true ) '
                        .notes=($n + "\n") |
                        (.fields[]? | select(.name == "metadata.keyDate")).value=$fv__m
                    ' \
                0<<<"${bwData}")"
                bw encode 0<<<"${bwData}" | bw edit item "$(jq -cr '.id' 0<<<"${bwData}")" 1> /dev/null
                eval "${__shOpt}"; unset __shOpt
            }
        }

        # Update Google Secret Manager (GSM).
        ( set +x; set -o pipefail
            function gsm-cli () {
                # This function need to be updated per
                #   `https://github.com/openshift/release/blob/main/hack/secret-manager.sh`.
                # The original script can only work in interactive session.

                podman run --rm -i \
                    -u 0:0 \
                    -p 127.0.0.1:8085:8085 \
                    -e SM_AUTH_DIR=/auth \
                    -e SM_BROWSER_REQUEST=/browser/url \
                    -e SM_CALLBACK_HOST=0.0.0.0 \
                    -e CLOUDSDK_CONFIG=/gcloud \
                    -e GOOGLE_CLOUD_QUOTA_PROJECT=openshift-ci-secrets \
                    --env-file <(echo _AWS__CFG) \
                    -v "${ssoAuth}:/auth:z" \
                    -v "${ssoInfo}:/browser:z" \
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
            function sso-cleanup() {
                typeset ssoRoot="${1:?}"; (($#)) && shift
                typeset -i ssoPID="${1:?}"; (($#)) && shift
                if ((ssoPID)); then
                    kill "${ssoPID}" 2> /dev/null || true
                    wait "${ssoPID}" 2> /dev/null || true
                fi
                rm -rf "${ssoRoot}/"
            }

            typeset ssoRoot="$(mktemp -d /tmp/gsm-cli.XXXXXX)"
            typeset ssoAuth="${ssoRoot}/auth" ssoInfo="${ssoRoot}/browser"
            typeset -i ssoPID=0
            trap 'sso-cleanup "${ssoRoot}" "${ssoPID}"' EXIT
            mkdir -p "${ssoAuth}" "${ssoInfo}"
            (
                typeset url=
                while true; do
                    if [[ -f "${ssoInfo}/url" ]]; then
                        url="$(0< "${ssoInfo}/url")"
                        rm -f "${ssoInfo}/url"
                        case ${url} in
                            (https://idp.ci.openshift.org/auth\?*)
                            printf \
                                '%s%s%s\n' \
                                'Open URL `' \
                                "${url}" \
                                '` in a browser on this machine.' \
                                1>&2
                            ;;
                        esac
                    fi
                    sleep 1
                done
            ) & ssoPID=$!

            typeset gsmSecPath="$(gsm-norm-path 'aws/.awscred')"
            typeset -i gsmSecExist=0
            eval "$(jq -r '.notes' 0<<<"${bwData}")"
            typeset -x _AWS__CFG="$(cat - 0<<crdEOF
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
crdEOF
)"$'\n'

            gcloud auth application-default print-access-token &> /dev/null || {
                echo 'Logging in to Google Cloud...'
                gcloud auth application-default login --no-launch-browser
            } || {
                echo 'You may NOT have access to Google Cloud.' 1>&2
                exit 1
            }
            gsmSecExist=$(gsm-cli "$(cat - 0<<scrEOF
python3 main.py list \
    -c ${_GSM__SEC_COL@Q} \
    -o json
scrEOF
            )" | jq -r --arg p "${gsmSecPath}" '
                (index($p) // -1) + 1
            ') 2>/dev/null || {
                echo \
                    'You do NOT have access to GSM Secret'\
                    "\`${gsmSecPath}\` in Collection \`${_GSM__SEC_COL}\`."\
                    1>&2
                exit 1
            }

            echo \
                'Creating or updating GSM Secret'\
                "\`${gsmSecPath}\` in Collection \`${_GSM__SEC_COL}\`."
            {
                if ((gsmSecExist)); then
                    gsm-cli "$(cat - 0<<scrEOF
python3 main.py update \
    -c ${_GSM__SEC_COL@Q} \
    --from-literal "\${_AWS__CFG}" \
    ${gsmSecPath@Q}
scrEOF
                    )"
                else
                    gsm-cli "$(cat - 0<<scrEOF
python3 main.py create \
    -c ${_GSM__SEC_COL@Q} \
    --from-literal "\${_AWS__CFG}" \
    ${gsmSecPath@Q} 0<<'ansEOF'
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
                    "\`${gsmSecPath}\` in Collection \`${_GSM__SEC_COL}\`."\
                    1>&2
                exit 1
            }
        true )

#       # Update HashiCorp Vault.
#       ( set +x
#           typeset vaultData= awsCfg=
#
#           vault token lookup &> /dev/null || {
#               echo 'Logging in to HashiCorp Vault...'
#               vault login 1> /dev/null
#           } || {
#               echo "You may NOT have access to HashiCorp Vault at \`${VAULT_ADDR}\`." 1>&2
#               exit 1
#           }
#           eval "$(jq -r '.notes' 0<<<"${bwData}")"
#           vaultData="$(vault kv get -mount="${_VAULT_MOUNT}" -format=json "selfservice/${_VAULT_KEY_SFX}")" || {
#               echo \
#                   "You do NOT have access to HashiCorp Vault Secret"\
#                   "\`${_VAULT_MOUNT}/selfservice/${_VAULT_KEY_SFX}\` at \`${VAULT_ADDR}\`."\
#                   1>&2
#               exit 1
#           }
#           e="$(jq -r '"\(.data.data.".awscred")."' 0<<<"${vaultData}")"
#           awsCfg="$(gawk -F '\\s*=\\s*' '
#               BEGIN{c=2}
#               (c){
#                   if ($1 == "aws_access_key_id") {
#                       c--
#                       $0=gensub(/(^[^=]*=\s*)\S*/,"\\1" ENVIRON["AWS_ACCESS_KEY_ID"],1)
#                   } else if ($1 == "aws_secret_access_key") {
#                       c--
#                       $0=gensub(/(^[^=]*=\s*)\S*/,"\\1" ENVIRON["AWS_SECRET_ACCESS_KEY"],1)
#                   }
#               }
#               {print}
#           ' 0<<<"${e}")"
#           [ "${awsCfg}" = "${e}" ] || {
#               echo \
#                   "Updating HashiCorp Vault Secret"\
#                   "\`${_VAULT_MOUNT}/selfservice/${_VAULT_KEY_SFX}\` at \`${VAULT_ADDR}\`."
#               vault kv destroy -mount="${_VAULT_MOUNT}" -versions="$(
#                   jq -r '.data.metadata.version' 0<<<"${vaultData}"
#               )" "selfservice/${_VAULT_KEY_SFX}" &> /dev/null # Ignore error as we may not have permission to delete.
#               {
#                   jq -r --rawfile fv__c <(set +x; printf '%s' "${awsCfg%.}") '
#                       .data.data | .".awscred"=$fv__c
#                   ' 0<<<"${vaultData}" |
#                   vault kv put -mount="${_VAULT_MOUNT}" "selfservice/${_VAULT_KEY_SFX}" - 1> /dev/null
#               } || {
#                   echo \
#                       "You do NOT have R/W access to HashiCorp Vault Secret"\
#                       "\`${_VAULT_MOUNT}/selfservice/${_VAULT_KEY_SFX}\` at \`${VAULT_ADDR}\`."\
#                       1>&2
#                   exit 1
#               }
#           }
#       true )

        true
cmdEOF
    )"; echo $?
```
</details>




## Resource Pruning
### IAM Roles
#### IAM Roles Clean Up
<details><summary>Cleaning Up Stale IAM Roles</summary>

```shell
__SHELL=0 \
    __DRY_RUN=1 \
    _BW__NOTE_NAME='...bwNoteName...' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    AWS_REGION=us-east-1 \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
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
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset iamRoleName= ocpClsID= hdr= e=
        typeset -a awsRegArr=(); IFS=$'\t' read -ra awsRegArr 0< <(
            aws ec2 describe-regions \
                --output text \
                --query 'Regions[].RegionName'
        )

        while read -r iamRoleName; do
            # Check IAM Role Name Pattern: ...clsName...-...5charID...
            ocpClsID="$([[ "${iamRoleName}" =~ ^(.+-[a-z0-9]{5})-(master|worker)-role$ ]] && echo "${BASH_REMATCH[1]}")" || continue

            # Check OCP Tag: kubernetes.io/cluster/${ocpClsID}
            [ "$(
                aws iam list-role-tags --role-name "${iamRoleName}" \
                    --output text --query "Tags[?(Key == 'kubernetes.io/cluster/${ocpClsID}')].[Value]"
            )" = owned ] || continue

            # Check Trusted Entity: ec2.amazonaws.com
            [ -z "$(
                aws iam get-role --role-name "${iamRoleName}" \
                    --output text \
                    --query "Role.AssumeRolePolicyDocument.Statement[?((Effect == 'Allow') && contains(Principal.Service, 'ec2.amazonaws.com'))]"
            )" ] && continue

            # Check if there is any running EC2 resource belongs to the Cluster.
            for e in "${awsRegArr[@]}"; do
                {
                    aws ec2 describe-instances \
                        --region "${e}" \
                        --filters \
                            "Name=tag-key,Values=kubernetes.io/cluster/${ocpClsID}" \
                            "Name=tag-value,Values=owned" \
                            "Name=instance-state-name,Values=running" \
                        --output text \
                        --query 'Reservations[*].Instances[*].InstanceId' |
                    grep -q .
                } && continue 2
            done

            if ((__DRY_RUN)); then
                echo "${hdr:=$'List of stale IAM Roles:\n    '}${iamRoleName}"
                hdr='    '
            else
                # Find the IAM Instance Profiles the Role is attached to and remove from it.
                while read -r e; do
                    echo "Detaching IAM Role \`${iamRoleName}\` from IAM Instance Profile \`${e}\`..."
                    aws iam remove-role-from-instance-profile --instance-profile-name "${e}" --role-name "${iamRoleName}" --no-cli-pager
                done 0< <(
                    aws iam list-instance-profiles \
                        --output text --query "InstanceProfiles[?contains(Roles[*].RoleName, '${iamRoleName}')].[InstanceProfileName]"
                )
                # Delete IAM Instance Profiles without any Roles.
                while read -r e; do
                    echo "Deleting empty IAM Instance Profile \`${e}\`..."
                    aws iam delete-instance-profile --instance-profile-name "${e}" --no-cli-pager
                done 0< <(
                    aws iam list-instance-profiles \
                        --output text --query 'InstanceProfiles[?(length(Roles) == `0`)].[InstanceProfileName]'
                )

                # Detach all AIM Permission Policies.
                while read -r e; do
                    echo "Detaching IAM Permission Policies \`${e}\` from IAM Role \`${iamRoleName}\`..."
                    aws iam detach-role-policy --role-name "${iamRoleName}" --policy-arn "${e}" --no-cli-pager
                done 0< <(
                    aws iam list-attached-role-policies --role-name "${iamRoleName}" \
                        --output text --query 'AttachedPolicies[*].[PolicyArn]'
                )

                # Delete all AIM Inline Permission Policies.
                while read -r e; do
                    echo "Deleting AIM Inline Permission Policies \`${e}\` from IAM Role \`${iamRoleName}\`..."
                    aws iam delete-role-policy --role-name "${iamRoleName}" --policy-name "${e}" --no-cli-pager
                done 0< <(
                    aws iam list-role-policies --role-name "${iamRoleName}" \
                        --output text --query 'PolicyNames[*].[@]'
                )

                # Delete the AIM Role.
                echo "Deleting IAM Role \`${iamRoleName}\`..."
                aws iam delete-role --role-name "${iamRoleName}" --no-cli-pager
            fi
        done 0< <(aws iam list-roles --output text --query 'Roles[*].[RoleName]')

        true
cmdEOF
    )"; echo $?
```
</details>



### IAM Users
#### IAM Users Clean Up
<details><summary>Cleaning Up Stale IAM Users</summary>

```shell
__SHELL=0 \
    __DRY_RUN=1 \
    _BW__NOTE_NAME='...bwNoteName...' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    AWS_REGION=us-east-1 \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
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
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset iamUserName= ocpClsID= hdr= e=
        typeset -a awsRegArr=(); IFS=$'\t' read -ra awsRegArr 0< <(
            aws ec2 describe-regions \
                --output text \
                --query 'Regions[].RegionName'
        )

        while read -r iamUserName; do
            # Check OCP Tag: kubernetes.io/cluster/...clsName...-...5charID...
            ocpClsID="$(
                aws iam list-user-tags --user-name "${iamUserName}" \
                    --output text \
                    --query 'Tags[?(starts_with(Key, `kubernetes.io/cluster/`) && (Value == `owned`))].Key' |
                sed -nE 's|^kubernetes.io/cluster/(.*-[a-z0-9]{5})$|\1|p'
            )" || continue
            [ -z "${ocpClsID}" ] && continue

            # Check if there is any running EC2 resource belongs to the Cluster.
            for e in "${awsRegArr[@]}"; do
                {
                    aws ec2 describe-instances \
                        --region "${e}" \
                        --filters \
                            "Name=tag-key,Values=kubernetes.io/cluster/${ocpClsID}" \
                            "Name=tag-value,Values=owned" \
                            "Name=instance-state-name,Values=running" \
                        --output text \
                        --query 'Reservations[*].Instances[*].InstanceId' |
                    grep -q .
                } && continue 2
            done

            if ((__DRY_RUN)); then
                echo "${hdr:=$'List of stale IAM Users:\n    '}${iamUserName}"
                hdr='    '
            else
                # Delete Access Keys.
                while read -r e; do
                    echo "Deleting IAM Access Key \`${e}\` from IAM User \`${iamUserName}\`..."
                    aws iam delete-access-key --user-name "${iamUserName}" --access-key-id "${e}" --no-cli-pager
                done 0< <(
                    aws iam list-access-keys --user-name "${iamUserName}" \
                        --output text --query 'AccessKeyMetadata[*].[AccessKeyId]'
                )

                # Detach IAM Permission Policies.
                while read -r e; do
                    echo "Detaching IAM Permission Policy \`${e}\` from IAM User \`${iamUserName}\`..."
                    aws iam detach-user-policy --user-name "${iamUserName}" --policy-arn "${e}" --no-cli-pager
                done 0< <(
                    aws iam list-attached-user-policies --user-name "${iamUserName}" \
                        --output text --query 'AttachedPolicies[*].[PolicyArn]'
                )

                # Delete IAM Inline Permission Policies.
                while read -r e; do
                    echo "Deleting IAM Inline Permission Policy \`${e}\` from IAM User \`${iamUserName}\`..."
                    aws iam delete-user-policy --user-name "${iamUserName}" --policy-name "${e}" --no-cli-pager
                done 0< <(
                    aws iam list-user-policies --user-name "${iamUserName}" \
                        --output text --query 'PolicyNames[*].[@]'
                )

                # Remove IAM User from all Groups.
                while read -r e; do
                    echo "Removing IAM User \`${iamUserName}\` from IAM Group \`${e}\`..."
                    aws iam remove-user-from-group --user-name "${iamUserName}" --group-name "${e}" --no-cli-pager
                done 0< <(
                    aws iam list-groups-for-user --user-name "${iamUserName}" \
                        --output text --query 'Groups[*].[GroupName]'
                )

                # Delete Login Profile (if exists).
                echo "Deleting Login Profile for IAM User \`${iamUserName}\`..."
                aws iam delete-login-profile --user-name "${iamUserName}" --no-cli-pager 2> /dev/null || true

                # Delete MFA Devices.
                while read -r e; do
                    echo "Deleting MFA Device \`${e}\` from IAM User \`${iamUserName}\`..."
                    aws iam deactivate-mfa-device --user-name "${iamUserName}" --serial-number "${e}" --no-cli-pager
                    # Only delete if it's a virtual MFA Device (ARN format).
                    [[ "${e}" =~ ^arn:aws:iam: ]] &&
                        aws iam delete-virtual-mfa-device --serial-number "${e}" --no-cli-pager
                done 0< <(
                    aws iam list-mfa-devices --user-name "${iamUserName}" \
                        --output text --query 'MFADevices[*].[SerialNumber]'
                )

                # Delete Signing Certificates.
                while read -r e; do
                    echo "Deleting Signing Certificate \`${e}\` from IAM User \`${iamUserName}\`..."
                    aws iam delete-signing-certificate --user-name "${iamUserName}" \
                        --certificate-id "${e}" --no-cli-pager
                done 0< <(
                    aws iam list-signing-certificates --user-name "${iamUserName}" \
                        --output text --query 'Certificates[*].[CertificateId]'
                )

                # Delete SSH Public Keys.
                while read -r e; do
                    echo "Deleting SSH Public Key \`${e}\` from IAM User \`${iamUserName}\`..."
                    aws iam delete-ssh-public-key --user-name "${iamUserName}" \
                        --ssh-public-key-id "${e}" --no-cli-pager
                done 0< <(
                    aws iam list-ssh-public-keys --user-name "${iamUserName}" \
                        --output text --query 'SSHPublicKeys[*].[SSHPublicKeyId]'
                )

                # Delete Service Specific Credentials.
                while read -r e; do
                    echo "Deleting Service Specific Credential \`${e}\` from IAM User \`${iamUserName}\`..."
                    aws iam delete-service-specific-credential --user-name "${iamUserName}" \
                        --service-specific-credential-id "${e}" --no-cli-pager
                done 0< <(
                    aws iam list-service-specific-credentials --user-name "${iamUserName}" \
                        --output text --query 'ServiceSpecificCredentials[*].[ServiceSpecificCredentialId]'
                )

                # Delete the IAM User.
                echo "Deleting IAM User \`${iamUserName}\`..."
                aws iam delete-user --user-name "${iamUserName}" --no-cli-pager
            fi
        done 0< <(aws iam list-users --output text --query 'Users[*].[UserName]')

        true
cmdEOF
    )"; echo $?
```
</details>



### Route53 Hosted Zones
#### Route53 Hosted Zones Clean Up
<details><summary>Cleaning Up Stale Route53 Hosted Zones and Cluster Records</summary>

```shell
__SHELL=0 \
    __DRY_RUN=1 \
    _BW__NOTE_NAME='...bwNoteName...' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    AWS_REGION=us-east-1 \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
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
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset hzID= hzName= ocpClsID= dnsRec= hdr= e=
        typeset -a awsRegArr=(); IFS=$'\t' read -ra awsRegArr 0< <(
            aws ec2 describe-regions \
                --output text \
                --query 'Regions[].RegionName'
        )

        # Cleaning Up Stale Private Hosted Zones
        while IFS=$'\t' read -r hzID hzName; do
            # Check Hosted Zone Tag Key Pattern: kubernetes.io/cluster/...clsName...-...5charID...
            ocpClsID="$(
                aws route53 list-tags-for-resource \
                    --resource-type hostedzone \
                    --resource-id "${hzID}" \
                    --output text \
                    --query 'ResourceTagSet.Tags[?(
                        starts_with(Key, `kubernetes.io/cluster/`) &&
                        (Value == `owned`)
                    )].Key' |
                sed -nE 's|^kubernetes.io/cluster/(.*-[a-z0-9]{5})$|\1|p'
            )" || continue
            [ -z "${ocpClsID}" ] && continue

            # Check if there is any running EC2 resource belongs to the Cluster.
            for e in "${awsRegArr[@]}"; do
                {
                    aws ec2 describe-instances \
                        --region "${e}" \
                        --filters \
                            "Name=tag-key,Values=kubernetes.io/cluster/${ocpClsID}" \
                            "Name=tag-value,Values=owned" \
                            "Name=instance-state-name,Values=running" \
                        --output text \
                        --query 'Reservations[*].Instances[*].InstanceId' |
                    grep -q .
                } && continue 2
            done

            if ((__DRY_RUN)); then
                echo "${hdr:=$'List of stale Private Hosted Zones:\n    '}${hzName}"
                hdr='    '
            else
                # Delete Private Hosted Zone.
                dnsRec="$(
                        aws route53 list-resource-record-sets \
                            --hosted-zone-id "${hzID}" \
                            --query "ResourceRecordSets[?((Type != 'NS') && (Type != 'SOA'))] "
                )"
                [ "${dnsRec}" != '[]' ] && {
                    echo "Deleting non-default DNS records from Private Hosted Zone \`${hzName}\`..."
                    aws route53 change-resource-record-sets \
                        --hosted-zone-id "${hzID}" \
                        --change-batch "$(
                            jq -cn --argjson r "${dnsRec}" \
                                '{"Changes": [
                                    $r[] | {"Action": "DELETE", "ResourceRecordSet": .}
                                ]}'
                        )" \
                        --no-cli-pager
                }
                echo "Deleting Private Hosted Zone \`${hzName}\`..."
                aws route53 delete-hosted-zone --id "${hzID}" --no-cli-pager

                # Delete Cluster Records from Public Hosted Zones.
                e="${hzName}"
                while IFS=$'\t' read -r hzID hzName; do
                    dnsRec="$(
                        aws route53 list-resource-record-sets \
                            --hosted-zone-id "${hzID}" \
                            --query "
                                ResourceRecordSets[?(
                                    (Type != 'NS') &&
                                    (Type != 'SOA') &&
                                    ends_with(Name, '${e}.')
                                )]
                            "
                    )"
                    [ "${dnsRec}" != '[]' ] && {
                        echo "Deleting Cluster DNS records from Public Hosted Zone \`${hzName}: *${e}\`..."
                        aws route53 change-resource-record-sets \
                            --hosted-zone-id "${hzID}" \
                            --change-batch "$(
                                jq -cn --argjson r "${dnsRec}" \
                                    '{"Changes": [
                                        $r[] | {"Action": "DELETE", "ResourceRecordSet": .}
                                    ]}'
                            )" \
                            --no-cli-pager
                    }
                done 0< <(
                    aws route53 list-hosted-zones \
                        --output text \
                        --query 'HostedZones[?(Config.PrivateZone == `false`)].[Id, Name]' |
                    sed -E 's|^/hostedzone/||;s/\.$//'
                )
            fi
        done 0< <(
            aws route53 list-hosted-zones \
                --output text \
                --query 'HostedZones[?(Config.PrivateZone == `true`)].[Id, Name]' |
            sed -E 's|^/hostedzone/||;s/\.$//'
        )

        # Cleaning up orphaned Cluster Records in Public Hosted Zones.
        hdr=
        while IFS=$'\t' read -r hzID hzName; do
            while IFS= read -r e; do
                # Check the Private Hosted Zone Name Pattern: ...clsName.......baseDomain...
                #   The `clsName` should not have `.` as part of OCP Cluster Name restriction.
                dnsRec="$([[ "${e}" =~ ^(\\052\.apps|api)\.([^.]+\."${hzName}")$ ]] && echo "${BASH_REMATCH[2]}")" || continue

                # Check the corresponding Private Hosted Zone.
                [ -z "$(
                    aws route53 list-hosted-zones \
                        --output text \
                        --query "
                            HostedZones[?(
                                (Config.PrivateZone == \`true\`) &&
                                (Name == '${dnsRec}.')
                            )].[Name]
                        "
                )" ] || continue

                if ((__DRY_RUN)); then
                    echo "${hdr:='List of orphaned Cluster Records in Public Hosted Zones `'"${hzName}"$'`:\n    '}${e}"
                    hdr='    '
                else
                    # Delete orphaned Cluster records from Public Hosted Zone.
                    dnsRec="$(
                        aws route53 list-resource-record-sets \
                            --hosted-zone-id "${hzID}" \
                            --query "
                                ResourceRecordSets[?(
                                    (Type != 'NS') &&
                                    (Type != 'SOA') &&
                                    (Name == '${e}.')
                                )]
                            "
                    )"
                    [ "${dnsRec}" != '[]' ] && {
                        echo "Deleting orphaned Cluster Records from Public Hosted Zone \`${hzName}: ${e}\`..."
                        aws route53 change-resource-record-sets \
                            --hosted-zone-id "${hzID}" \
                            --change-batch "$(
                                jq -cn --argjson r "${dnsRec}" \
                                    '{"Changes": [
                                        $r[] | {"Action": "DELETE", "ResourceRecordSet": .}
                                    ]}'
                            )" \
                            --no-cli-pager
                    }
                fi
            done 0< <(
                aws route53 list-resource-record-sets \
                    --hosted-zone-id "${hzID}" \
                    --output text \
                    --query "ResourceRecordSets[?((Type != 'NS') && (Type != 'SOA'))].[Name]" |
                sed -E 's/\.$//'
            )
        done 0< <(
            aws route53 list-hosted-zones \
                --output text \
                --query 'HostedZones[?(Config.PrivateZone == `false`)].[Id, Name]' |
            sed -E 's|^/hostedzone/||;s/\.$//'
        )

        true
cmdEOF
    )"; echo $?
```
</details>



### S3 General Purpose Buckets
#### S3 General Purpose Buckets Clean Up
<details><summary>Cleaning Up Stale S3 General Purpose Buckets</summary>

```shell
__SHELL=0 \
    __DRY_RUN=1 \
    _AWS__PRUNED_REGIONS='(...awsPrunedReg1... ...awsPrunedReg2... ... ...awsPrunedRegN...)' \
    _AWS__PRUNER_EXEMP_LIST='(...awsPrunerExemp1... ...awsPrunerExemp2... ... ...awsPrunerExempN...)' \
    _AWS__PRUNER_TTL__H='...awsPrunerTTLinHour...' \
    _BW__NOTE_NAME='...bwNoteName...' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    AWS_REGION=us-east-1 \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
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
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\\[DEBUG\\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset s3Bucket= ocpClsID= hdr= e=
        typeset -a awsPrunerExempList="${_AWS__PRUNER_EXEMP_LIST}"
        typeset -a awsRegArr=(); IFS=$'\t' read -ra awsRegArr 0< <(
            aws ec2 describe-regions \
                --output text \
                --query 'Regions[].RegionName'
        )

        while read -r s3Bucket; do
            # Check if S3 Bucket is in exemption list.
            for e in "${awsPrunerExempList[@]}"; do
                [ "${s3Bucket}" = "${e}" ] && continue 2
            done

            # Check S3 Bucket Tag Key Pattern: kubernetes.io/cluster/...clsName...-...5charID...
            ocpClsID="$(
                aws s3api get-bucket-tagging \
                    --bucket "${s3Bucket}" \
                    --output text \
                    --query 'TagSet[?(starts_with(Key, `kubernetes.io/cluster/`) && (Value == `owned`))].Key' \
                    2> /dev/null |
                sed -nE 's|^kubernetes.io/cluster/(.*-[a-z0-9]{5})$|\1|p'
            )" || true

            if [ -n "${ocpClsID}" ]; then
                # Check if there is any running EC2 resource belongs to the Cluster.
                for e in "${awsRegArr[@]}"; do
                    {
                        aws ec2 describe-instances \
                            --region "${e}" \
                            --filters \
                                "Name=tag-key,Values=kubernetes.io/cluster/${ocpClsID}" \
                                "Name=tag-value,Values=owned" \
                                "Name=instance-state-name,Values=running" \
                            --output text \
                            --query 'Reservations[*].Instances[*].InstanceId' |
                        grep -q .
                    } && continue 2
                done
            else
                # No OCP tag found, check if Bucket is in pruned regions and satisfied the TTL.
                e="$(
                    aws s3api get-bucket-location \
                        --bucket "${s3Bucket}" \
                        --output text
                )"
                [ "${e}" = None ] && e=us-east-1    # For `us-east-1` it returns `None`, normalize it.
                [[ "${_AWS__PRUNED_REGIONS}" =~ (\(|\ )"${e}"(\ |\)) ]] || continue
                (( $(date +%s) - (_AWS__PRUNER_TTL__H * 3600) > $(date -d "$(
                    aws s3api list-buckets \
                        --query "Buckets[?Name=='${s3Bucket}'].CreationDate" \
                        --output text
                )" +%s))) || continue
            fi

            if ((__DRY_RUN)); then
                echo "${hdr:=$'List of stale S3 General Purpose Buckets:\n    '}${s3Bucket}"
                hdr='    '
            else
                echo "Processing S3 GP Bucket \`${s3Bucket}\`:"

                # Remove Object Versions.
                while read -r e; do
                    echo "    Deleting Object Version \`$(
                        echo "${e}" | jq -r '.Objects[] | "\(.Key);\(.VersionId)"'
                    )\`..."
                    aws s3api delete-objects \
                        --bucket "${s3Bucket}" \
                        --delete "${e}" \
                        --no-cli-pager \
                        1> /dev/null
                done 0< <(
                    aws s3api list-object-versions \
                        --bucket "${s3Bucket}" \
                        --output json \
                        --query 'Versions[*] || `[]`' |
                    jq -c '.[] | {Objects: [{Key: .Key, VersionId: .VersionId}]}'
                )

                # Remove Delete Markers.
                while read -r e; do
                    echo "    Deleting Delete Marker \`$(
                        echo "${e}" | jq -r '.Objects[] | "\(.Key);\(.VersionId)"'
                    )\`..."
                    aws s3api delete-objects \
                        --bucket "${s3Bucket}" \
                        --delete "${e}" \
                        --no-cli-pager \
                        1> /dev/null
                done 0< <(
                    aws s3api list-object-versions \
                        --bucket "${s3Bucket}" \
                        --output json \
                        --query 'DeleteMarkers[*] || `[]`' |
                    jq -c '.[] | {Objects: [{Key: .Key, VersionId: .VersionId}]}'
                )

                # Delete the S3 Bucket.
                echo "Deleting S3 Bucket \`${s3Bucket}\`..."
                aws s3api delete-bucket --bucket "${s3Bucket}" --no-cli-pager
            fi
        done 0< <(aws s3api list-buckets --output text --query 'Buckets[*].[Name]')

        true
cmdEOF
    )"; echo $?
```
</details>

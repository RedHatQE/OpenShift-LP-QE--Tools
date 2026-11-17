# AWS Simple Email Service
## Verification
<details><summary>Verifying Sender eMail Domain</summary>

```shell
__SHELL=0 \
    _AWS__SES__SNDR_DOM=...senderDomain... \
    _AWS__DNS_BASE_DOM=...dnsBaseDomain... \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    AWS_REGION=us-west-1 \
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
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this \`DEBUG\` session!!!

        typeset e=
        typeset -i wInt=0 wMax=0
        typeset -a dkimTkns=()

        # Get DKIM tokens for DNS verification.
        read -ra dkimTkns < <(
            aws sesv2 get-email-identity \
                --email-identity "${_AWS__SES__SNDR_DOM}" \
                --output text \
                --query 'DkimAttributes.Tokens[]' \
                2> /dev/null ||
            aws sesv2 create-email-identity \
                --email-identity "${_AWS__SES__SNDR_DOM}" \
                --output text \
                --query 'DkimAttributes.Tokens[]'
        )

        cat - 0<<txtEOF
--------------------------------------------------------------------------------
Add the following DNS Records to Route 53 to verify domain:
--------------------------------------------------------------------------------
DKIM CNAME Records (for eMail signing):
$(
    for e in "${dkimTkns[@]}"; do
        cat - 0<<loopEOF
    Name:  ${e}._domainkey.${_AWS__SES__SNDR_DOM}
    Type:  CNAME
    Value: ${e}.dkim.amazonses.com

loopEOF
    done
)
--------------------------------------------------------------------------------
txtEOF

        # Get Route 53 Hosted Zone ID.
        typeset r53ZoneID="$(
            aws route53 list-hosted-zones-by-name \
                --dns-name "${_AWS__DNS_BASE_DOM}" \
                --output text \
                --query "HostedZones[?
                    (Name == \`\"${_AWS__DNS_BASE_DOM}.\"\`)
                ].Id" | \
                cut -d/ -f3
        )"; [ -n "${r53ZoneID}" ]

        # Create DNS Records.
        aws route53 wait resource-record-sets-changed --id "$(
            aws route53 change-resource-record-sets \
                --hosted-zone-id "${r53ZoneID}" \
                --change-batch "$(
                    jq -cn \
                        --arg domain "${_AWS__SES__SNDR_DOM}" \
                        --argjson tokens "$(
                            printf '%s\n' "${dkimTkns[@]}" |
                            jq -cRs 'split("\n")[:-1]'
                        )" \
                        '{
                            Changes: (
                                $tokens |
                                map({
                                    Action: "UPSERT",
                                    ResourceRecordSet: {
                                        Name: (. + "._domainkey." + $domain),
                                        Type: "CNAME",
                                        TTL: 300,
                                        ResourceRecords: [{
                                            Value: (. + ".dkim.amazonses.com")
                                        }]
                                    }
                                })
                            )
                        }'
                )" \
                --output text \
                --query 'ChangeInfo.Id'
        )"

        # Monitor SES Sender Domain verification.
        (   # Isolate `SECONDS` reset.
            # SES Sender Domain verification.
            SECONDS=0 wInt=15 wMax=1800     # 30 min. Max.
            while ((SECONDS < wMax)); do
                typeset dkimStatus="$(
                    aws sesv2 get-email-identity \
                        --email-identity "${_AWS__SES__SNDR_DOM}" \
                        --output text \
                        --query 'DkimAttributes.Status'
                )"
                [[ "${dkimStatus}" == SUCCESS ]] && break
                echo "Waited ${SECONDS}/${wMax} sec.: "\
'Verifying SES Sender Domain...' 1>&2
                sleep ${wInt}
            done
            ((SECONDS >= wMax)) && {
                cat - 0<<errEOF 1>&2
Timed out waiting for SES Sender Domain verification.
Note:
    Script timeout after 30 minutes (SSO session time limit).
    DNS propagation may still be in progress and can take up to 72 hours.
    Re-run this script later to check verification status OR execute:
        watch -wn 60 "\$(cat - 0<<monEOF
            \$(
                [ -v BASH_ALIASES[aws] ] &&
                echo "\${BASH_ALIASES[aws]}" ||
                echo aws
            ) sesv2 get-email-identity \\\\
                --region "\${AWS_REGION}" \\\\
                --email-identity chaos.lp.devcluster.openshift.com \\\\
                --query '{
                    Verified: VerifiedForSendingStatus,
                    DKIM: DkimAttributes.Status
                }'
monEOF
        )"
errEOF
                exit 2
            }
            # Final status.
            aws sesv2 get-email-identity \
                --email-identity "${_AWS__SES__SNDR_DOM}" \
                --output table \
                --no-cli-pager
        )

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Verifying Recipient eMail Address (Sandbox Mode)</summary>

In sandbox mode, you can only send eMails to verified email addresses. Verify
recipient addresses before testing:
```shell
__SHELL=0 \
    _AWS__SES__RCPT_EMAIL=user@domain.com \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    AWS_REGION=us-west-1 \
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
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this \`DEBUG\` session!!!

        # Create eMail Identity for Recipient eMail verification.
        aws sesv2 get-email-identity \
            --email-identity "${_AWS__SES__RCPT_EMAIL}" \
            --output text \
            --query 'VerifiedForSendingStatus' \
            2> /dev/null ||
        aws sesv2 create-email-identity \
            --email-identity "${_AWS__SES__RCPT_EMAIL}" \
            --output table \
            --no-cli-pager

        cat - 0<<txtEOF
--------------------------------------------------------------------------------
E-Mail Verification Requested
--------------------------------------------------------------------------------
Recipient: ${_AWS__SES__RCPT_EMAIL}

A verification eMail has been sent to this address.
The recipient must click the verification link in the eMail.

Verification typically completes within a few minutes.

You can check verification status with:
    aws sesv2 get-email-identity \\
        --email-identity ${_AWS__SES__RCPT_EMAIL@Q} \\
        --query 'VerifiedForSendingStatus' \\
        --no-cli-pager
--------------------------------------------------------------------------------
txtEOF

        true
cmdEOF
    )"; echo $?
```
</details>


## SMTP Credential
<details><summary>Creating IAM User for SMTP Authentication</summary>

```shell
__SHELL=0 \
    _AWS__SES__IAM_USER=ses--smtp--auth \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=admin \
   x_AWS__SES_TO=3600 \
    _BW__NOTE_NAME='...bwNoteName...' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    AWS_REGION=us-west-1 \
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
        {
            typeset __shOpt="$(shopt -po xtrace)"; set +x
            [ -n "${BW_SESSION}" ] && bw sync || {
                echo 'You do NOT have an active and sync:ed BitWarden Session!!!' 1>&2
                exit 1
            }
            eval "${__shOpt}"; unset __shOpt
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this \`DEBUG\` session!!!

        typeset bwData=
        typeset iamPolARN="arn:aws:iam::aws:policy/AmazonSESFullAccess"
        typeset e=

        {
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

        # Create IAM user for SES SMTP.
        {
            aws iam get-user \
                --user-name "${_AWS__SES__IAM_USER}" \
                --output text \
                --query 'User.Arn' \
                --no-cli-pager 2> /dev/null ||
            aws iam create-user \
                --user-name "${_AWS__SES__IAM_USER}" \
                --tags "$(
                    jq -cn \
                        --arg name "${_AWS__SES__IAM_USER}" \
                        '[{"Key": "Name", "Value": $name}]'
                )" \
                --no-cli-pager
        }

        # Attach IAM Permission Policy for SES Sending to IAM User.
        [ -z "$(
            aws iam list-attached-user-policies \
                --user-name "${_AWS__SES__IAM_USER}" \
                --output text \
                --query "AttachedPolicies[?
                    (PolicyArn == \`\"${iamPolARN}\"\`)
                ].PolicyArn"
        )" ] && aws iam attach-user-policy \
            --user-name "${_AWS__SES__IAM_USER}" \
            --policy-arn "${iamPolARN}" \
            --no-cli-pager

        # Delete stale Access Keys.
        for e in $(
            aws iam list-access-keys --user-name "${_AWS__SES__IAM_USER}" |
            jq -r '.AccessKeyMetadata[] | select(.AccessKeyId != "'"$(
                eval "$(echo "${bwData}" | jq -r '.notes')"
                echo "${_SVC__SMTP_RLY__USR}"
            )"'") | .AccessKeyId'
        ); do
            aws iam delete-access-key \
                --user-name "${_AWS__SES__IAM_USER}" \
                --access-key-id "${e}"
        done

        # Create Access Key for SMTP.
        typeset accKeyJSON="$(
            aws iam create-access-key \
                --user-name "${_AWS__SES__IAM_USER}" \
                --output json
        )"
        typeset accKeyID="$(
            jq -r '.AccessKey.AccessKeyId' 0<<<"${accKeyJSON}"
        )"
        typeset secAccKey="$(
            jq -r '.AccessKey.SecretAccessKey' 0<<<"${accKeyJSON}"
        )"

        # Convert to SES SMTP credentials.
        # SES SMTP password is derived from secret access key using AWS Signature
        #   Version 4 signing process.
        typeset smtpPwd="$(python3 -c "$(cat - 0<<scrEOF
import hmac
import hashlib
import base64

def sign(key, msg):
    return hmac.new(key, msg.encode('utf-8'), hashlib.sha256).digest()

# AWS Signature Version 4 signing chain.
sig = sign(('AWS4${secAccKey}').encode('utf-8'), '11111111')    # Date (const.).
sig = sign(sig, '${AWS_REGION}')                                # Region.
sig = sign(sig, 'ses')                                          # Service.
sig = sign(sig, 'aws4_request')                                 # Terminal.
sig = sign(sig, 'SendRawEmail')                                 # Message.
print(base64.b64encode(bytes([0x04]) + sig).decode('utf-8'))    # Version 4.
scrEOF
        )")"

        # Update BitWarden Note.
        {
            typeset __shOpt="$(shopt -po xtrace)"; set +x
            bwData="$(jq -r \
                --arg n "$(
                    # Within MTA (Message Transfer Agent), Host FQDN in a
                    #   bracket means skip MX Record and do A/AAAA Record
                    #   lookup directly.
                    # AWS SES EndPoint is NOT Main Exchange Domain, hence no MX
                    #   Record, to use bracket to speed up the lookup.
                    export _SVC__SMTP_RLY__HST="[email-smtp.${AWS_REGION}.amazonaws.com]:587"
                    export _SVC__SMTP_RLY__USR="${accKeyID}"
                    export _SVC__SMTP_RLY__PWD="${smtpPwd}"
                    typeset -p _SVC__SMTP_RLY__HST _SVC__SMTP_RLY__USR _SVC__SMTP_RLY__PWD
                )" \
                --rawfile fv__m_1 <( set +x
                    printf '%s' "$(
                        typeset url="smtp://${accKeyID}:${smtpPwd}@email-smtp.${AWS_REGION}.amazonaws.com:587 (TLS)"
                        typeset -p url
                    )"
                true ) \
                --rawfile fv__m_2 <( set +x
                    printf '%s' "$(
                        typeset url="smtp://email-smtp.${AWS_REGION}.amazonaws.com:587 (TLS)"
                        typeset -p url
                    )"
                true ) \
                '
                    .notes=($n + "\n") |
                    .fields|=((. // []) | (
                        map(select(
                            (.name != "metadata.URL.wiCred") and
                            (.name != "metadata.URL.woCred")
                        )) +
                        [{name: "metadata.URL.wiCred", value: $fv__m_1, type: 1}] +
                        [{name: "metadata.URL.woCred", value: $fv__m_2, type: 0}]
                    ))
                ' \
            0<<<"${bwData}")"
            bw encode 0<<<"${bwData}" | bw edit item "$(jq -cr '.id' 0<<<"${bwData}")" 1> /dev/null
            eval "${__shOpt}"; unset __shOpt
        }

        true
cmdEOF
    )"; echo $?
```
</details>


## Production Access
<details><summary>Request Production Access (Send to Any eMail)</summary>

By default, SES is in **sandbox mode** - you can only send eMails to verified
eMail addresses. To send to any recipient, request production access:
```shell
__SHELL=0 \
    _AWS__SES__DAILY_QUOTA=1200 \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    AWS_REGION=us-west-1 \
    AWS_ACCOUNT_ID=624914081466 \
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
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this \`DEBUG\` session!!!

        # Get SES Service Code for Support API.
        typeset svcCode="$(
            aws support describe-services \
                --region us-east-1 \
                --output text \
                --query 'services[?
                    (name == `"Simple Email Service (SES)"`)
                ].code'
        )"; [ -n "${svcCode}" ]

        # Get SES Production Access Category Code.
        typeset catCode="$(
            aws support describe-services \
                --region us-east-1 \
                --service-code "${svcCode}" \
                --output text \
                --query 'services[0].categories[?
                    (name == `"Production Access"`)
                ].code'
        )"; [ -n "${catCode}" ]

        # Create support case for SES production access.
        typeset caseID="$(
            aws support create-case \
                --region us-east-1 \
                --subject "SES Production Access Request - ${AWS_REGION}" \
                --service-code "${svcCode}" \
                --category-code "${catCode}" \
                --severity-code low \
                --communication-body "$(cat - 0<<txtEOF
I am requesting to move my SES account out of sandbox mode for the
\`${AWS_REGION}\` region.

Use Cases:
  - Internal notifications and user invitations for self-hosted services.

Requested Daily Sending Quota: ${_AWS__SES__DAILY_QUOTA}

I acknowledge that I will:
  - Only send to recipients who have opted in.
  - Handle bounces and complaints appropriately.
  - Maintain a low complaint rate (< 0.1%).
  - Comply with AWS Acceptable Use Policy.
txtEOF
                )" \
                --output text \
                --query 'caseId'
        )"; [ -n "${caseID}" ]

        cat - 0<<txtEOF
--------------------------------------------------------------------------------
SES Production Access Request Submitted
--------------------------------------------------------------------------------
Case ID:    ${caseID}
Region:     ${AWS_REGION}
Quota:      ${_AWS__SES__DAILY_QUOTA} eMails/day

Expected Response Time: 24-48 hours

You can check the case status with:
    aws support describe-cases \\
        --region us-east-1 \\
        --case-id-list ${caseID@Q} \\
        --no-cli-pager
--------------------------------------------------------------------------------
txtEOF

        true
cmdEOF
    )"; echo $?
```
</details>


## Notes
  - **URL**: smtp://email-smtp.${AWS_REGION}.amazonaws.com:587
  - **Port 587**: Use STARTTLS (port 587) for SMTP Relay. Port 25 is blocked
    by AWS on EC2 instances.
  - **Sandbox Mode**: By default, SES only allows sending to verified eMail
    addresses. Request production access to send to any recipient.
  - **DKIM Signing**: Automatically enabled for domain verification. Improves
    eMail deliverability and reduces spam classification.
  - **Bounce Handling**: SES tracks bounces and complaints. Configure SNS
    notifications for production use.
  - **Cost**: First 62,000 eMails/month are free when sent from EC2. After that,
     $0.10 per 1,000 eMails.

# AWS VM Management
## Creating VM Instance
### Creating Virtual Network
<details><summary>Creating VPC and SubNet</summary>

```shell
__SHELL=0 \
    _AWS__NET_PFX='...netPfx..' \
    _AWS__VPC_CIDR='172.24.0.0/20' \
    _AWS__VPC_SN_CIDR='172.24.0.0/26' \
    _AWS__AZ_SFX=a \
    _AWS__SN_SFX=pub0 \
    _AWS__APP_KIND='...appKind...' \
    _AWS__SG_DESCR='...sgDescr...' \
    _AWS__USE_SSO=0 \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    _BW__NOTE_NAME='...bwNoteName...' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    AWS_REGION=us-west-1 \
    AWS_ACCOUNT_ID='...awsAccID...' \
    AWS_CONFIG_FILE="${HOME}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials" \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        {
            if ((_AWS__USE_SSO)); then
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
            else
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
            fi
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this \`DEBUG\` session!!!

        typeset e=
        typeset awsAZ="${AWS_REGION}${_AWS__AZ_SFX}"
        typeset awsSGnameSfx="sg--${_AWS__APP_KIND}"
        typeset awsTagSpec="$(cat - 0<<'cfgEOF'
ResourceType: ''
Tags:
  - Key: Name
    Value: ''
cfgEOF
        )"
        typeset -a arr=()
        typeset -A awsSGrules=(
            [ssh]='0|tcp|22|22|0.0.0.0/0'
            [http]='0|tcp|80|80|0.0.0.0/0'
            [https]='0|tcp|443|443|0.0.0.0/0'
        )

        # Create VPC.
        typeset vpcID="$(
            typeset vpcName="${_AWS__NET_PFX}--vpc"
            typeset vpcID="$(
                aws ec2 describe-vpcs \
                    --filters "Name=tag:Name,Values=${vpcName}" \
                    --output text \
                    --query 'Vpcs[0].VpcId'
            )"
            if [ "${vpcID}" = None ]; then
                aws ec2 create-vpc \
                    --cidr-block "${_AWS__VPC_CIDR}" \
                    --instance-tenancy 'default' \
                    --tag-specifications "$({
                        yq -o json eval . | jq -c \
                            --arg resType 'vpc' \
                            --arg name "${vpcName}" \
                            '
                                .ResourceType=$resType |
                                .Tags[0].Value=$name
                            '
                    } 0<<<"${awsTagSpec}")" \
                    --output text \
                    --query 'Vpc.VpcId'
            else
                echo "${vpcID}"
            fi
        )"; [ -n "${vpcID}" ]

        # Set VPC settings.
        aws ec2 modify-vpc-attribute \
            --vpc-id "${vpcID}" \
            --enable-dns-hostnames '{"Value":true}'

        # Show VPC.
        aws ec2 describe-vpcs --vpc-ids "${vpcID}" --output table --no-cli-pager

        # Show VPC attributes.
        for e in enableDnsHostnames enableDnsSupport; do
            aws ec2 describe-vpc-attribute --vpc-id "${vpcID}" \
                --attribute "${e}" \
                --output table --no-cli-pager
        done

        # Set Main Route Table Name.
        aws ec2 create-tags \
            --resources "$(
                aws ec2 describe-route-tables \
                    --filters \
                        "Name=vpc-id,Values=${vpcID}" \
                        "Name=association.main,Values=true" \
                    --output text \
                    --query 'RouteTables[0].RouteTableId'
            )" \
            --tags "Key=Name,Value=${_AWS__NET_PFX}--rtb-main"

        # Set Default Security Group Name.
        aws ec2 create-tags \
            --resources "$(
                aws ec2 describe-security-groups \
                    --filters \
                        "Name=vpc-id,Values=${vpcID}" \
                        "Name=group-name,Values=default" \
                    --output text \
                    --query 'SecurityGroups[0].GroupId'
            )" \
            --tags "Key=Name,Value=${_AWS__NET_PFX}--sg--vpc"

        # Create VPC EndPoint for S3 (Gateway EndPoint).
        typeset vpcEPid="$(
            typeset vpcEPname="${_AWS__NET_PFX}--vpce--s3"
            typeset vpcEPid="$(
                aws ec2 describe-vpc-endpoints \
                    --filters "Name=tag:Name,Values=${vpcEPname}" \
                    --output text \
                    --query 'VpcEndpoints[0].VpcEndpointId'
            )"
            if [ "${vpcEPid}" = None ]; then
                aws ec2 create-vpc-endpoint \
                    --vpc-id "${vpcID}" \
                    --service-name "com.amazonaws.${AWS_REGION}.s3" \
                    --tag-specifications "$({
                        yq -o json eval . | jq -c \
                            --arg resType 'vpc-endpoint' \
                            --arg name "${vpcEPname}" \
                            '
                                .ResourceType=$resType |
                                .Tags[0].Value=$name
                            '
                    } 0<<<"${awsTagSpec}")" \
                    --output text \
                    --query 'VpcEndpoint.VpcEndpointId'
            else
                echo "${vpcEPid}"
            fi
        )"

        # Show VPC EndPoint.
        aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "${vpcEPid}" \
            --output table --no-cli-pager

        # Create SubNet.
        typeset snID="$(
            typeset snName="${_AWS__NET_PFX}--subnet-${_AWS__SN_SFX}--${awsAZ}"
            typeset snID="$(
                aws ec2 describe-subnets \
                    --filters "Name=tag:Name,Values=${snName}" \
                    --output text \
                    --query 'Subnets[0].SubnetId'
            )"
            if [ "${snID}" = None ]; then
                aws ec2 create-subnet \
                    --vpc-id "${vpcID}" \
                    --cidr-block "${_AWS__VPC_SN_CIDR}" \
                    --availability-zone "${awsAZ}" \
                    --tag-specifications "$({
                        yq -o json eval . | jq -c \
                            --arg resType 'subnet' \
                            --arg name "${snName}" \
                            '
                                .ResourceType=$resType |
                                .Tags[0].Value=$name
                            '
                    } 0<<<"${awsTagSpec}")" \
                    --output text \
                    --query 'Subnet.SubnetId'
            else
                echo "${snID}"
            fi
        )"; [ -n "${snID}" ]

        # Set SubNet settings.
        aws ec2 modify-subnet-attribute \
            --subnet-id "${snID}" \
            --enable-resource-name-dns-a-record
        aws ec2 modify-subnet-attribute \
            --subnet-id "${snID}" \
            --private-dns-hostname-type-on-launch resource-name
        aws ec2 modify-subnet-attribute \
            --subnet-id "${snID}" \
            --map-public-ip-on-launch

        # Show SubNet.
        aws ec2 describe-subnets --subnet-ids "${snID}" \
            --output table --no-cli-pager

        # Create Route Table.
        typeset rtbID="$(
            typeset rtbName="${_AWS__NET_PFX}--rtb-${_AWS__SN_SFX}--${awsAZ}"
            typeset rtbID="$(
                aws ec2 describe-route-tables \
                    --filters "Name=tag:Name,Values=${rtbName}" \
                    --output text \
                    --query 'RouteTables[0].RouteTableId'
            )"
            if [ "${rtbID}" = None ]; then
                aws ec2 create-route-table \
                    --vpc-id "${vpcID}" \
                    --tag-specifications "$({
                        yq -o json eval . | jq -c \
                            --arg resType 'route-table' \
                            --arg name "${rtbName}" \
                            '
                                .ResourceType=$resType |
                                .Tags[0].Value=$name
                            '
                    } 0<<<"${awsTagSpec}")" \
                    --output text \
                    --query 'RouteTable.RouteTableId'
            else
                echo "${rtbID}"
            fi
        )"

        # Create Internet Gateway and Route.
        if [[ "${_AWS__SN_SFX}" == pub* ]]; then
            typeset igwID="$(
                typeset igwName="${_AWS__NET_PFX}--igw"
                typeset igwID="$(
                    aws ec2 describe-internet-gateways \
                        --filters "Name=tag:Name,Values=${igwName}" \
                        --output text \
                        --query 'InternetGateways[0].InternetGatewayId'
                )"
                if [ "${igwID}" = None ]; then
                    aws ec2 create-internet-gateway \
                        --tag-specifications "$({
                            yq -o json eval . | jq -c \
                                --arg resType 'internet-gateway' \
                                --arg name "${igwName}" \
                                '
                                    .ResourceType=$resType |
                                    .Tags[0].Value=$name
                                '
                        } 0<<<"${awsTagSpec}")" \
                        --output text \
                        --query 'InternetGateway.InternetGatewayId'
                else
                    echo "${igwID}"
                fi
            )"

            # Attach Internet Gateway to VPC.
            if [ "$(
                aws ec2 describe-internet-gateways \
                    --internet-gateway-ids "${igwID}" \
                    --output text \
                    --query "InternetGateways[0].Attachments[?
                        (VpcId == \`\"${vpcID}\"\`)
                    ].State"
            )" != "available" ]; then
                aws ec2 attach-internet-gateway \
                    --internet-gateway-id "${igwID}" \
                    --vpc-id "${vpcID}" \
                    --no-cli-pager
            fi

            # Show Internet Gateway.
            aws ec2 describe-internet-gateways \
                --internet-gateway-ids "${igwID}" \
                --output table --no-cli-pager

            # Create Route.
            typeset routeGWid="$(
                aws ec2 describe-route-tables \
                    --route-table-ids "${rtbID}" \
                    --output text \
                    --query 'RouteTables[0].Routes[?
                        (DestinationCidrBlock == `"0.0.0.0/0"`)
                    ].GatewayId'
            )"
            if [ -z "${routeGWid}" ]; then
                aws ec2 create-route \
                    --route-table-id "${rtbID}" \
                    --destination-cidr-block '0.0.0.0/0' \
                    --gateway-id "${igwID}" \
                    --no-cli-pager
            elif [ "${routeGWid}" != "${igwID}" ]; then
                aws ec2 replace-route \
                    --route-table-id "${rtbID}" \
                    --destination-cidr-block '0.0.0.0/0' \
                    --gateway-id "${igwID}" \
                    --no-cli-pager
            fi
        elif [[ "${_AWS__SN_SFX}" == prv* ]]; then
            # Associate S3 VPC Endpoint with Route Table.
            if ! grep -qw "${rtbID}" 0<<<"$(
                aws ec2 describe-vpc-endpoints \
                    --vpc-endpoint-ids "${vpcEPid}" \
                    --output text \
                    --query 'VpcEndpoints[0].RouteTableIds[]'
            )"; then
                aws ec2 modify-vpc-endpoint \
                    --vpc-endpoint-id "${vpcEPid}" \
                    --add-route-table-ids "${rtbID}" \
                    --no-cli-pager
            fi
        fi

        # Associate Route Table with SubNet.
        if [ -z "$(
            aws ec2 describe-route-tables \
                --route-table-ids "${rtbID}" \
                --output text \
                --query "RouteTables[0].Associations[?
                    (SubnetId == \`\"${snID}\"\`)
                ].RouteTableAssociationId"
        )" ]; then
            aws ec2 associate-route-table \
                --route-table-id "${rtbID}" \
                --subnet-id "${snID}" \
                --no-cli-pager
        fi

        # Show Route Table.
        aws ec2 describe-route-tables \
            --route-table-ids "${rtbID}" \
            --output table --no-cli-pager

        # Create Security Group.
        typeset sgID="$(
            typeset sgName="${_AWS__NET_PFX}--${awsSGnameSfx}"
            typeset sgID="$(
                aws ec2 describe-security-groups \
                    --filters \
                        "Name=vpc-id,Values=${vpcID}" \
                        "Name=group-name,Values=${sgName}" \
                    --output text \
                    --query 'SecurityGroups[0].GroupId'
            )"
            if [ "${sgID}" = None ]; then
                aws ec2 create-security-group \
                    --group-name "${sgName}" \
                    --description "${_AWS__SG_DESCR}" \
                    --vpc-id "${vpcID}" \
                    --tag-specifications "$({
                        yq -o json eval . | jq -c \
                            --arg resType 'security-group' \
                            --arg name "${sgName}" \
                            '
                                .ResourceType=$resType |
                                .Tags[0].Value=$name
                            '
                    } 0<<<"${awsTagSpec}")" \
                    --output text \
                    --query 'GroupId'
            else
                echo "${sgID}"
            fi
        )"; [ -n "${sgID}" ]

        # Add Security Group Rules.
        for e in "${!awsSGrules[@]}"; do
            IFS='|' read -ra arr 0<<<"${awsSGrules[${e}]}"
            typeset -i ruleDir="${arr[0]}"
            typeset ruleDirSfx=
            ((ruleDir)) && {
                arr[0]=true
                ruleDirSfx=er
            } || {
                arr[0]=false
                ruleDirSfx=ir
            }
            typeset cidrParName= rngsParName= cidrKey=
            if [[ "${arr[4]}" == *:* ]]; then
                cidrParName=CidrIpv6
                rngsParName=Ipv6Ranges
                cidrKey=CidrIpv6
            else
                cidrParName=CidrIpv4
                rngsParName=IpRanges
                cidrKey=CidrIp
            fi
            typeset ruleName="${_AWS__NET_PFX}--${awsSGnameSfx}--${ruleDirSfx}--${e}"
            typeset ruleID="$(
                aws ec2 describe-security-group-rules \
                    --filters "Name=group-id,Values=${sgID}" \
                    --output text \
                    --query "SecurityGroupRules[?(
                        (IsEgress == \`${arr[0]}\`) &&
                        (IpProtocol == \`\"${arr[1]}\"\`) &&
                        (FromPort == \`${arr[2]}\`) &&
                        (ToPort == \`${arr[3]}\`) &&
                        (${cidrParName} == \`\"${arr[4]}\"\`)
                    )].SecurityGroupRuleId"
            )"
            if [ -z "${ruleID}" ]; then
                ((ruleDir)) &&
                aws ec2 authorize-security-group-egress \
                    --group-id "${sgID}" \
                    --ip-permissions \
                        "IpProtocol=${arr[1]},FromPort=${arr[2]},ToPort=${arr[3]},${rngsParName}=[
                            {${cidrKey}=${arr[4]},Description='${ruleName}'},
                        ]" \
                    --tag-specifications "$({
                        yq -o json eval . | jq -c \
                            --arg resType 'security-group-rule' \
                            --arg name "${ruleName}" \
                            '
                                .ResourceType=$resType |
                                .Tags[0].Value=$name
                            '
                    } 0<<<"${awsTagSpec}")" \
                    --no-cli-pager ||
                aws ec2 authorize-security-group-ingress \
                    --group-id "${sgID}" \
                    --ip-permissions \
                        "IpProtocol=${arr[1]},FromPort=${arr[2]},ToPort=${arr[3]},${rngsParName}=[
                            {${cidrKey}=${arr[4]},Description='${ruleName}'},
                        ]" \
                    --tag-specifications "$({
                        yq -o json eval . | jq -c \
                            --arg resType 'security-group-rule' \
                            --arg name "${ruleName}" \
                            '
                                .ResourceType=$resType |
                                .Tags[0].Value=$name
                            '
                    } 0<<<"${awsTagSpec}")" \
                    --no-cli-pager
            else
                aws ec2 modify-security-group-rules \
                    --group-id "${sgID}" \
                    --security-group-rules \
                        "SecurityGroupRuleId=${ruleID},SecurityGroupRule={
                            IpProtocol=${arr[1]},
                            FromPort=${arr[2]},
                            ToPort=${arr[3]},
                            ${cidrParName}=${arr[4]},
                            Description='${ruleName}'
                        }" \
                    --no-cli-pager
                aws ec2 create-tags \
                    --resources "${ruleID}" \
                    --tags "Key=Name,Value=${ruleName}"
            fi
        done

        # Show Security Group.
        aws ec2 describe-security-groups --group-ids "${sgID}" \
            --output table --no-cli-pager

        # Create VPC EndPoints for SSM (Interface EndPoints).
        typeset -a ssmSvcs=(ssm ssmmessages ec2messages)
        for e in "${ssmSvcs[@]}"; do
            typeset vpcEPid="$(
                typeset vpcEPname="${_AWS__NET_PFX}--vpce--${e}"
                typeset vpcEPid="$(
                    aws ec2 describe-vpc-endpoints \
                        --filters "Name=tag:Name,Values=${vpcEPname}" \
                        --output text \
                        --query 'VpcEndpoints[0].VpcEndpointId'
                )"
                if [ "${vpcEPid}" = None ]; then
                    aws ec2 create-vpc-endpoint \
                        --vpc-id "${vpcID}" \
                        --vpc-endpoint-type Interface \
                        --service-name "com.amazonaws.${AWS_REGION}.${e}" \
                        --subnet-ids "${snID}" \
                        --security-group-ids "${sgID}" \
                        --tag-specifications "$({
                            yq -o json eval . | jq -c \
                                --arg resType 'vpc-endpoint' \
                                --arg name "${vpcEPname}" \
                                '
                                    .ResourceType=$resType |
                                    .Tags[0].Value=$name
                                '
                        } 0<<<"${awsTagSpec}")" \
                        --output text \
                        --query 'VpcEndpoint.VpcEndpointId'
                else
                    echo "${vpcEPid}"
                fi
            )"
            # Show VPC EndPoint.
            aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "${vpcEPid}" \
                --output table --no-cli-pager
        done

        true
cmdEOF
    )"; echo $?
```
</details>


### Creating VM
<details><summary>Creating EC2 Instance</summary>

```shell
__SHELL=0 \
    _AWS__NET_PFX='...netPfx..' \
    _AWS__AZ_SFX=a \
    _AWS__SN_SFX=pub0 \
    _AWS__APP_KIND='...appKind...' \
    _AWS__SSH_KEY__NAME='...sshKeyName...' \
    _AWS__SSH_KEY__PUB="${HOME}/.ssh/...sshKeyPub..." \
    _AWS__EC2__AMI_NAME='...ec2AMIname..' \
    _AWS__EC2__NAME_SFX="${_AWS__APP_KIND}--host" \
    _AWS__EC2__INST_TYPE=t4g.small \
    _AWS__EC2__RESTRICT_ACC=0 \
    _AWS__DNS_BASE_DOM='...dnsBaseDom...' \
    _AWS__DNS_SUB_DOM='' \
    _AWS__DNS_HOST_NAME='..dnsHostName...' \
    _AWS__DNS_SVC_PFX_ARR='(...dnsSvcPfx1... ...dnsSvcPfx2...)' \
    _AWS__USE_SSO=0 \
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
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        {
            if ((_AWS__USE_SSO)); then
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
            else
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
            fi
            aws configure list --no-cli-pager
            aws sts get-caller-identity --no-cli-pager
        } 1>&2
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this \`DEBUG\` session!!!

        typeset e=
        typeset awsAZ="${AWS_REGION}${_AWS__AZ_SFX}"
        typeset iamRoleName="${_AWS__NET_PFX}--role--ssm"
        typeset iamPolARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        typeset dnsHstFQDN="${_AWS__DNS_HOST_NAME}${_AWS__DNS_SUB_DOM:+.${_AWS__DNS_SUB_DOM}}.${_AWS__DNS_BASE_DOM}"

        typeset awsTagSpec="$(cat - 0<<'cfgEOF'
ResourceType: ''
Tags:
  - Key: Name
    Value: ''
cfgEOF
        )"
        eval "$(
            typeset -a dnsSvcFQDNarr=()
            typeset -a _AWS__DNS_SVC_PFX_ARR="${_AWS__DNS_SVC_PFX_ARR}"
            for e in "${_AWS__DNS_SVC_PFX_ARR[@]}"; do
                dnsSvcFQDNarr+=("${e}.${dnsHstFQDN}")
            done
            typeset -p dnsSvcFQDNarr
        )"

        # Import SSH Key Pair.
        typeset sshKeyID="$(
            typeset sshKeyID="$(
                aws ec2 describe-key-pairs \
                    --key-names "${_AWS__SSH_KEY__NAME}" \
                    --output text \
                    --query 'KeyPairs[0].KeyPairId' \
                    2> /dev/null || true
            )"
            if [ -z "${sshKeyID}" ]; then
                aws ec2 import-key-pair \
                    --key-name "${_AWS__SSH_KEY__NAME}" \
                    --public-key-material "fileb://${_AWS__SSH_KEY__PUB}" \
                    --tag-specifications "$({
                        yq -o json eval . | jq -c \
                            --arg resType 'key-pair' \
                            --arg name "${_AWS__SSH_KEY__NAME}" \
                            '
                                .ResourceType=$resType |
                                .Tags[0].Value=$name
                            '
                    } 0<<<"${awsTagSpec}")" \
                    --output text \
                    --query 'KeyPairId'
            else
                echo "${sshKeyID}"
            fi
        )"

        # Show SSH Key Pair.
        aws ec2 describe-key-pairs \
            --key-pair-ids "${sshKeyID}" \
            --output table --no-cli-pager

        # Get SubNet ID.
        typeset snID="$(
            aws ec2 describe-subnets \
                --filters \
                    "Name=tag:Name,Values=${_AWS__NET_PFX}--subnet-${_AWS__SN_SFX}--${awsAZ}" \
                --output text \
                --query 'Subnets[0].SubnetId'
        )"; [ -n "${snID}" ]

        # Get Security Group ID.
        typeset sgID="$(
            aws ec2 describe-security-groups \
                --filters \
                    "Name=tag:Name,Values=${_AWS__NET_PFX}--sg--${_AWS__APP_KIND}" \
                --output text \
                --query 'SecurityGroups[0].GroupId'
        )"; [ -n "${sgID}" ]

        # Get AMI ID.
        typeset amiID="$(
            aws ec2 describe-images \
                --filters "Name=tag:Name,Values=${_AWS__EC2__AMI_NAME}" \
                --output text \
                --query 'Images[0].ImageId'
        )"; [ -n "${amiID}" ]

        # Create IAM Role for SSM.
        {
            aws iam get-role \
                --role-name "${iamRoleName}" \
                --output text \
                --query 'Role.Arn' \
                --no-cli-pager 2> /dev/null ||
            aws iam create-role \
                --role-name "${iamRoleName}" \
                --assume-role-policy-document '{
                    "Version": "2012-10-17",
                    "Statement": [{
                        "Effect": "Allow",
                        "Principal": {"Service": "ec2.amazonaws.com"},
                        "Action": "sts:AssumeRole"
                    }]
                }' \
                --tags "$(
                    jq -cn \
                        --arg name "${iamRoleName}" \
                        '[{"Key": "Name", "Value": $name}]'
                )" \
                --no-cli-pager
        }

        # Show IAM Role.
        aws iam get-role --role-name "${iamRoleName}" \
            --output table --no-cli-pager

        # Attach IAM Permission Policy for SSM to IAM Role.
        [ -z "$(
            aws iam list-attached-role-policies \
                --role-name "${iamRoleName}" \
                --output text \
                --query "AttachedPolicies[?
                    (PolicyArn == \`\"${iamPolARN}\"\`)
                ].PolicyArn"
        )" ] && aws iam attach-role-policy \
            --role-name "${iamRoleName}" \
            --policy-arn "${iamPolARN}" \
            --no-cli-pager

        # Show IAM Role attached IAM Permission Policies.
        aws iam list-attached-role-policies --role-name "${iamRoleName}" \
            --output table --no-cli-pager

        # Create IAM Instance Profile.
        {
            aws iam get-instance-profile \
                --instance-profile-name "${iamRoleName}" \
                --output text \
                --query 'InstanceProfile.Arn' \
                --no-cli-pager 2> /dev/null ||
            aws iam create-instance-profile \
                --instance-profile-name "${iamRoleName}" \
                --tags "$(
                    jq -cn \
                        --arg name "${iamRoleName}" \
                        '[{"Key": "Name", "Value": $name}]'
                )" \
                --no-cli-pager
        }

        # Add IAM Role to IAM Instance Profile.
        [ -z "$(
            aws iam get-instance-profile \
                --instance-profile-name "${iamRoleName}" \
                --output text \
                --query "InstanceProfile.Roles[?
                    (RoleName == \`\"${iamRoleName}\"\`)
                ].RoleName"
        )" ] && aws iam add-role-to-instance-profile \
            --instance-profile-name "${iamRoleName}" \
            --role-name "${iamRoleName}" \
            --no-cli-pager

        # Show IAM Instance Profile.
        aws iam get-instance-profile \
            --instance-profile-name "${iamRoleName}" \
            --output table --no-cli-pager

        # Create EC2 Instance.
        typeset ec2ID="$(
            typeset ec2Name="${_AWS__NET_PFX}--ec2--${_AWS__EC2__NAME_SFX}"
            typeset ec2ID="$(
                aws ec2 describe-instances \
                    --filters \
                        "Name=tag:Name,Values=${ec2Name}" \
                        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
                    --output text \
                    --query 'Reservations[0].Instances[0].InstanceId'
            )"
            if [ "${ec2ID}" = None ]; then
                aws ec2 run-instances \
                    --block-device-mappings '[{
                        "DeviceName": "/dev/xvda",
                        "Ebs": {
                            "DeleteOnTermination": true,
                            "VolumeType": "gp3",
                            "Encrypted": true,
                            "KmsKeyId": "alias/aws/ebs"
                        }
                    }]' \
                    --image-id "${amiID}" \
                    --instance-type "${_AWS__EC2__INST_TYPE}" \
                    --key-name "${_AWS__SSH_KEY__NAME}" \
                    --monitoring '{"Enabled": false}' \
                    --placement '{"Tenancy": "default"}' \
                    --credit-specification '{"CpuCredits": "unlimited"}' \
                    --hibernation-options '{"Configured": false}' \
                    --metadata-options '{
                        "HttpTokens": "required",
                        "HttpEndpoint": "enabled"
                    }' \
                    --private-dns-name-options '{
                        "HostnameType": "resource-name",
                        "EnableResourceNameDnsARecord": true,
                        "EnableResourceNameDnsAAAARecord": false
                    }' \
                    --maintenance-options '{"AutoRecovery": "default"}' \
                    --network-performance-options '{
                        "BandwidthWeighting": "default"
                    }' \
                    --instance-initiated-shutdown-behavior 'stop' \
                    --network-interfaces "$(
                        jq -cn \
                            --arg snID "${snID}" \
                            --arg sgID "${sgID}" \
                            '{
                                SubnetId: $snID,
                                AssociatePublicIpAddress: true,
                                DeviceIndex: 0,
                                Groups: [$sgID]
                            }'
                    )" \
                    --iam-instance-profile "Name=${iamRoleName}" \
                    --ebs-optimized \
                    --count 1 \
                    --tag-specifications "$(
                        yq -o json eval . 0<<<"${awsTagSpec}" | jq -c \
                            --arg ec2Name "${ec2Name}" \
                            --arg hddName "${ec2Name}--hdd--root" \
                            --arg nicName "${ec2Name}--nic--0" \
                            '[(
                                . |
                                .ResourceType="instance" |
                                .Tags[0].Value=$ec2Name
                            ), (
                                . |
                                .ResourceType="volume" |
                                .Tags[0].Value=$hddName
                            ), (
                                . |
                                .ResourceType="network-interface" |
                                .Tags[0].Value=$nicName
                            )]'
                    )" \
                    --output text \
                    --query 'Instances[0].InstanceId'
            else
                echo "${ec2ID}"
            fi
        )"; [ -n "${ec2ID}" ]

        # Set EC2 Instance Settings.
        aws ec2 modify-instance-attribute \
            --instance-id "${ec2ID}" \
            --disable-api-termination
        aws ec2 modify-instance-attribute \
            --instance-id "${ec2ID}" \
            --disable-api-stop

        # Set Access Tier Tag.
        {
            ((_AWS__EC2__RESTRICT_ACC)) &&
            aws ec2 create-tags \
                --resources "${ec2ID}" \
                --tags 'Key=AccessTier,Value=Restricted'
        }

        # Allocate Elastic IP.
        typeset eipID="$(
            typeset eipName="${_AWS__NET_PFX}--eip--${_AWS__APP_KIND}--ipv4-public"
            typeset eipID="$(
                aws ec2 describe-addresses \
                    --filters "Name=tag:Name,Values=${eipName}" \
                    --output text \
                    --query 'Addresses[0].AllocationId'
            )"
            if [ "${eipID}" = None ]; then
                aws ec2 allocate-address \
                    --domain vpc \
                    --tag-specifications "$(
                        yq -o json eval . 0<<<"${awsTagSpec}" | jq -c \
                            --arg resType 'elastic-ip' \
                            --arg name "${eipName}" \
                            '.ResourceType=$resType | .Tags[0].Value=$name'
                    )" \
                    --output text \
                    --query 'AllocationId'
            else
                echo "${eipID}"
            fi
        )"; [ -n "${eipID}" ]

        # Associate Elastic IP with EC2 Instance.
        [ "$(
            aws ec2 describe-addresses \
                --allocation-ids "${eipID}" \
                --output text \
                --query 'Addresses[0].AssociationId'
        )" = None ] && aws ec2 associate-address \
            --instance-id "${ec2ID}" \
            --allocation-id "${eipID}" \
            --no-cli-pager

        # Show Elastic IP.
        aws ec2 describe-addresses \
            --allocation-ids "${eipID}" \
            --output table --no-cli-pager

        # Get Elastic IP IPv4 address.
        typeset eipIPv4="$(
            aws ec2 describe-addresses \
                --allocation-ids "${eipID}" \
                --output text \
                --query 'Addresses[0].PublicIp'
        )"; [ -n "${eipIPv4}" ]

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

        # Create or update Route 53 Hosted Zone DNS A Records.
        aws route53 wait resource-record-sets-changed --id "$(
            aws route53 change-resource-record-sets \
                --hosted-zone-id "${r53ZoneID}" \
                --change-batch "$(
                    jq -cn \
                        --arg hstFQDN "${dnsHstFQDN}" \
                        --argjson svcFQDNarr "$(
                            printf '%s\n' "${dnsSvcFQDNarr[@]}" |
                            jq -cRs 'split("\n")[:-1]'
                        )" \
                        --arg ip "${eipIPv4}" \
                        '{Changes: ([{
                            Action: "UPSERT",
                            ResourceRecordSet: {
                                Name: $hstFQDN,
                                Type: "A",
                                TTL: 300,
                                ResourceRecords: [{Value: $ip}]
                            }
                        }] + (
                            $svcFQDNarr |
                            map({
                                Action: "UPSERT",
                                ResourceRecordSet: {
                                    Name: .,
                                    Type: "A",
                                    TTL: 300,
                                    ResourceRecords: [{Value: $ip}]
                                }
                            })
                        ))}'
                )" \
                --output text \
                --query 'ChangeInfo.Id'
        )"

        # Show DNS Records.
        aws route53 list-resource-record-sets \
            --hosted-zone-id "${r53ZoneID}" \
            --query "ResourceRecordSets[?(
                (Name == \`\"${dnsHstFQDN}.\"\`)$(
                    for e in "${dnsSvcFQDNarr[@]}"; do
                        echo -n " || (Name == \`\"${e}.\"\`)"
                    done
                )
            )]" \
            --output table --no-cli-pager

        # Show EC2 Instance.
        aws ec2 describe-instances \
            --instance-ids "${ec2ID}" \
            --output table --no-cli-pager

        true
cmdEOF
    )"; echo $?
```
</details>



## VM Instance Access
### SSM
<details><summary>Default User Login</summary>

```shell
__SHELL=0 \
    _AWS__NET_PFX='...netPfx..' \
    _AWS__APP_KIND='...appKind...' \
    _AWS__EC2__NAME_SFX="${_AWS__APP_KIND}--host" \
    _AWS__EC2_DEF_USER='' \
    _AWS__SSM_STARTSES_OPTS='()' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=readonlywithinstanceconnect \
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

        typeset usrName="${1-${_AWS__EC2_DEF_USER}}"; (($#)) && shift
        typeset ssmStartSesOpts="${1:-${_AWS__SSM_STARTSES_OPTS:-()}}"; (($#)) && shift

        typeset ssmCmdTail=
        typeset ec2ID=
        typeset ec2Name="${_AWS__NET_PFX}--ec2--${_AWS__EC2__NAME_SFX}"
        typeset -a ssmStartSesOpts="${ssmStartSesOpts}"

        ec2ID="$(
            aws ec2 describe-instances \
                --filters \
                    "Name=tag:Name,Values=${ec2Name}" \
                    "Name=instance-state-name,Values=running" \
                --output text \
                --query 'Reservations[0].Instances[0].InstanceId'
        )"; [ -n "${ec2ID}" ]
        usrName="${usrName:-1000}"  # Assume default User is having UID 1000.

        (($#)) && {
            [ -z "${1}" ] && {
                shift   # Using SSM User.
                (($#)) && {
                    [ -z "${1}" ] &&
                        ssmCmdTail="${ssmStartSesOpts[@]@Q}" || # Bare Session.
                        ssmCmdTail="\
                            --document-name 'AWS-StartInteractiveCommand' \
                            --parameters \"\$(
                                jq -cn --arg c \"\$(echo \"\${@@Q}\")\" \
                                    '{\"command\": [\$c]}'
                            )\" \
                            ${ssmStartSesOpts[@]@Q}
                        "   # Non-Interactive Session.
                } || ssmCmdTail="\
                    --document-name 'AWS-StartInteractiveCommand' \
                    --parameters \"\$(
                        jq -cn --arg c \"/bin/sh -c '\"\${SHELL}\" -l'\" \
                            '{\"command\": [\$c]}'
                    )\" \
                    ${ssmStartSesOpts[@]@Q}
                "   # Interactive Session.
            } || ssmCmdTail="\
                --document-name 'AWS-StartInteractiveCommand' \
                --parameters \"\$(
                    typeset c=\"\${@@Q}\"
                    jq -cn \
                        --arg c 'sudo su -c '\"\${c@Q}\"' - \"\$(\
                            id -un '\"\${usrName@Q}\"'\
                        )\"' \
                        '{\"command\": [\$c]}'
                )\" \
                ${ssmStartSesOpts[@]@Q}
            "   # Non-Interactive Session.
        } || ssmCmdTail="\
            --document-name 'AWS-StartInteractiveCommand' \
            --parameters \"\$(
                jq -cn \
                    --arg c 'sudo su - \"\$(id -un '\"\${usrName@Q}\"')\"' \
                    '{\"command\": [\$c]}'
            )\" \
            ${ssmStartSesOpts[@]@Q}
        "   # Interactive Session.

        # Connect to EC2 Instance via SSM.
        eval "aws ssm start-session --target ${ec2ID@Q} ${ssmCmdTail}"

        true
cmdEOF
    )" '' '' ''; echo $?
```
</details>


### EC2 Instance Connect
<details><summary>SSH via EC2 Instance Connect</summary>

```shell
__SHELL=0 \
    _AWS__NET_PFX='...netPfx..' \
    _AWS__APP_KIND='...appKind...' \
    _AWS__EC2__NAME_SFX="${_AWS__APP_KIND}--host" \
    _AWS__EC2_DEF_USER='' \
    _AWS__SSH__OPTS='()' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=readonlywithinstanceconnect \
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

        typeset usrName="${1-${_AWS__EC2_DEF_USER}}"; (($#)) && shift
        typeset sshOpts="${1:-${_AWS__SSH__OPTS:-()}}"; (($#)) && shift

        typeset tmpDir= tty=
        typeset ec2ID= ec2AZ= ec2FQDN=
        typeset ec2Name="${_AWS__NET_PFX}--ec2--${_AWS__EC2__NAME_SFX}"
        typeset -a sshOpts="${sshOpts}"

        ec2ID="$(
            aws ec2 describe-instances \
                --filters \
                    "Name=tag:Name,Values=${ec2Name}" \
                    "Name=instance-state-name,Values=running" \
                --output text \
                --query 'Reservations[0].Instances[0].InstanceId'
        )"; [ -n "${ec2ID}" ]
        ec2AZ="$(
            # Get EC2 Instance Availability Zone.
            aws ec2 describe-instances \
                --instance-ids "${ec2ID}" \
                --output text \
                --query '
                    Reservations[0].Instances[0].Placement.AvailabilityZone
                '
        )"; [ -n "${ec2AZ}" ]
        ec2FQDN="$(
            # Get EC2 Instance public FQDN.
            aws ec2 describe-instances \
                --instance-ids "${ec2ID}" \
                --output text \
                --query 'Reservations[0].Instances[0].PublicDnsName'
        )"; [ -n "${ec2FQDN}" ]
        usrName="${usrName:-$(
            # Determine default OS User from AMI.
            case $(
                aws ec2 describe-images \
                    --image-ids "$(
                        aws ec2 describe-instances \
                            --instance-ids "${ec2ID}" \
                            --output text \
                            --query 'Reservations[0].Instances[0].ImageId'
                    )" \
                    --output text \
                    --query 'Images[0].Name'
            ) in
              (*ubuntu*)        echo ubuntu;;
              (*debian*)        echo admin;;
              (*rhel*|*RHEL*)   ;&
              (*amzn*|*al2023*) ;&
              (*)               echo ec2-user;;
            esac
        )}"
        (($#)) || tty=-t

        # Setup CleanUp Trap.
        tmpDir="$(mktemp -d /tmp/aws--ec2-connect.XXXXXX)"
        trap "rm -rf ${tmpDir@Q}/" EXIT

        # Generate temporary SSH Key Pair and send Public Key to EC2 Instance.
        ssh-keygen -q -t rsa -f "${tmpDir}/key" -N ''
        [ "$(
            aws ec2-instance-connect send-ssh-public-key \
                --instance-id "${ec2ID}" \
                --instance-os-user "${usrName}" \
                --availability-zone "${ec2AZ}" \
                --ssh-public-key "file://${tmpDir}/key.pub" \
                --output text --query 'Success'
        )" = True ] || {
            echo 'Failed to send SSH public key to EC2 instance.' 1>&2
            exit 1
        }

        # Connect via SSH using the temporary Key (valid for 60 seconds).
        eval "
            ssh ${tty} \
                -o LogLevel=ERROR \
                -o UserKnownHostsFile=/dev/null \
                -o StrictHostKeyChecking=no \
                -i "${tmpDir}/key" \
                ${sshOpts[@]@Q} \
                ${usrName@Q}@${ec2FQDN@Q} ${@@Q}
        "

        true
cmdEOF
    )" '' '' ''; echo $?
```
</details>



## VM Instance Housekeeping
### Powering On
<details><summary>Starting Instance</summary>

```shell
__SHELL=0 \
    _AWS__NET_PFX='...netPfx..' \
    _AWS__APP_KIND='...appKind...' \
    _AWS__EC2__NAME_SFX="${_AWS__APP_KIND}--host" \
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

        typeset ec2Name="${_AWS__NET_PFX}--ec2--${_AWS__EC2__NAME_SFX}"

        typeset ec2ID="$(
            aws ec2 describe-instances \
                --filters \
                    "Name=tag:Name,Values=${ec2Name}" \
                    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
                --output text \
                --query 'Reservations[0].Instances[0].InstanceId'
        )"; [ -n "${ec2ID}" ]

        # Start EC2 Instance.
        aws ec2 start-instances --instance-ids "${ec2ID}" --no-cli-pager

        # Enable stop protection.
        aws ec2 modify-instance-attribute \
            --instance-id "${ec2ID}" \
            --disable-api-stop

        true
cmdEOF
    )"; echo $?
```
</details>


### Resetting
<details><summary>Rebooting Instance</summary>

```shell
__SHELL=0 \
    _AWS__NET_PFX='...netPfx..' \
    _AWS__APP_KIND='...appKind...' \
    _AWS__EC2__NAME_SFX="${_AWS__APP_KIND}--host" \
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

        typeset ec2Name="${_AWS__NET_PFX}--ec2--${_AWS__EC2__NAME_SFX}"

        typeset ec2ID="$(
            aws ec2 describe-instances \
                --filters \
                    "Name=tag:Name,Values=${ec2Name}" \
                    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
                --output text \
                --query 'Reservations[0].Instances[0].InstanceId'
        )"; [ -n "${ec2ID}" ]

        # Reboot EC2 Instance.
        aws ec2 reboot-instances --instance-ids "${ec2ID}" --no-cli-pager

        true
cmdEOF
    )"; echo $?
```
</details>


### Powering Off
<details><summary>Stopping Instance</summary>

```shell
__SHELL=0 \
    _AWS__NET_PFX='...netPfx..' \
    _AWS__APP_KIND='...appKind...' \
    _AWS__EC2__NAME_SFX="${_AWS__APP_KIND}--host" \
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

        typeset ec2Name="${_AWS__NET_PFX}--ec2--${_AWS__EC2__NAME_SFX}"

        typeset ec2ID="$(
            aws ec2 describe-instances \
                --filters \
                    "Name=tag:Name,Values=${ec2Name}" \
                    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
                --output text \
                --query 'Reservations[0].Instances[0].InstanceId'
        )"; [ -n "${ec2ID}" ]

        # Disable stop protection.
        aws ec2 modify-instance-attribute \
            --instance-id "${ec2ID}" \
            --no-disable-api-stop

        # Stop EC2 Instance.
        aws ec2 stop-instances --instance-ids "${ec2ID}" --no-cli-pager
        aws ec2 wait instance-stopped --instance-ids "${ec2ID}"

        true
cmdEOF
    )"; echo $?
```
</details>



## Creating VM Image Template

Some steps require running scripts on the VM. Connect to it via direct SSH
(if it has been set up accordingly) or any of the
[VM Instance Access](#VMInstanceAccess) methods.

### Building AMI
<details><summary>Creating AMI Generator VM</summary>

```shell
__SHELL=0 \
    _AWS__NET_PFX='...netPfx..' \
    _AWS__AZ_SFX=a \
    _AWS__SN_SFX=pub0 \
    _AWS__APP_KIND='...appKind...' \
    _AWS__SSH_KEY__NAME='...sshKeyName...' \
    _AWS__SSH_KEY__PUB="${HOME}/.ssh/...sshKeyPub..." \
    _AWS__EC2__AMI_NAME='...ec2AMIname..' \
    _AWS__EC2__NAME_SFX="ami--generator" \
    _AWS__EC2__INST_TYPE=t4g.micro \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=admin \
   x_AWS__SES_TO=3600 \
    AWS_REGION=us-west-1 \
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
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this \`DEBUG\` session!!!

        typeset awsAZ="${AWS_REGION}${_AWS__AZ_SFX}"
        typeset iamRoleName="${_AWS__NET_PFX}--role--ssm"
        typeset iamPolARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        typeset awsTagSpec="$(cat - 0<<'cfgEOF'
ResourceType: ''
Tags:
  - Key: Name
    Value: ''
cfgEOF
        )"

        # Import SSH Key Pair.
        typeset sshKeyID="$(
            typeset sshKeyID="$(
                aws ec2 describe-key-pairs \
                    --key-names "${_AWS__SSH_KEY__NAME}" \
                    --output text \
                    --query 'KeyPairs[0].KeyPairId' \
                    2> /dev/null || true
            )"
            if [ -z "${sshKeyID}" ]; then
                aws ec2 import-key-pair \
                    --key-name "${_AWS__SSH_KEY__NAME}" \
                    --public-key-material "fileb://${_AWS__SSH_KEY__PUB}" \
                    --tag-specifications "$({
                        yq -o json eval . | jq -c \
                            --arg resType 'key-pair' \
                            --arg name "${_AWS__SSH_KEY__NAME}" \
                            '
                                .ResourceType=$resType |
                                .Tags[0].Value=$name
                            '
                    } 0<<<"${awsTagSpec}")" \
                    --output text \
                    --query 'KeyPairId'
            else
                echo "${sshKeyID}"
            fi
        )"

        # Show SSH Key Pair.
        aws ec2 describe-key-pairs \
            --key-pair-ids "${sshKeyID}" \
            --output table --no-cli-pager

        # Get SubNet ID.
        typeset snID="$(
            aws ec2 describe-subnets \
                --filters \
                    "Name=tag:Name,Values=${_AWS__NET_PFX}--subnet-${_AWS__SN_SFX}--${awsAZ}" \
                --output text \
                --query 'Subnets[0].SubnetId'
        )"; [ -n "${snID}" ]

        # Get Security Group ID.
        typeset sgID="$(
            aws ec2 describe-security-groups \
                --filters \
                    "Name=tag:Name,Values=${_AWS__NET_PFX}--sg--${_AWS__APP_KIND}" \
                --output text \
                --query 'SecurityGroups[0].GroupId'
        )"; [ -n "${sgID}" ]

        # Get AMI ID.
        typeset amiID="$(
            aws ec2 describe-images \
                --filters "Name=tag:Name,Values=${_AWS__EC2__AMI_NAME}" \
                --output text \
                --query 'Images[0].ImageId'
        )"; [ -n "${amiID}" ]

        # Create IAM Role for SSM.
        {
            aws iam get-role \
                --role-name "${iamRoleName}" \
                --output text \
                --query 'Role.Arn' \
                --no-cli-pager 2> /dev/null ||
            aws iam create-role \
                --role-name "${iamRoleName}" \
                --assume-role-policy-document '{
                    "Version": "2012-10-17",
                    "Statement": [{
                        "Effect": "Allow",
                        "Principal": {"Service": "ec2.amazonaws.com"},
                        "Action": "sts:AssumeRole"
                    }]
                }' \
                --tags "$(
                    jq -cn \
                        --arg name "${iamRoleName}" \
                        '[{"Key": "Name", "Value": $name}]'
                )" \
                --no-cli-pager
        }

        # Show IAM Role.
        aws iam get-role --role-name "${iamRoleName}" \
            --output table --no-cli-pager

        # Attach IAM Permission Policy for SSM to IAM Role.
        [ -z "$(
            aws iam list-attached-role-policies \
                --role-name "${iamRoleName}" \
                --output text \
                --query "AttachedPolicies[?
                    (PolicyArn == \`\"${iamPolARN}\"\`)
                ].PolicyArn"
        )" ] && aws iam attach-role-policy \
            --role-name "${iamRoleName}" \
            --policy-arn "${iamPolARN}" \
            --no-cli-pager

        # Show IAM Role attached IAM Permission Policies.
        aws iam list-attached-role-policies --role-name "${iamRoleName}" \
            --output table --no-cli-pager

        # Create IAM Instance Profile.
        {
            aws iam get-instance-profile \
                --instance-profile-name "${iamRoleName}" \
                --output text \
                --query 'InstanceProfile.Arn' \
                --no-cli-pager 2> /dev/null ||
            aws iam create-instance-profile \
                --instance-profile-name "${iamRoleName}" \
                --tags "$(
                    jq -cn \
                        --arg name "${iamRoleName}" \
                        '[{"Key": "Name", "Value": $name}]'
                )" \
                --no-cli-pager
        }

        # Add IAM Role to IAM Instance Profile.
        [ -z "$(
            aws iam get-instance-profile \
                --instance-profile-name "${iamRoleName}" \
                --output text \
                --query "InstanceProfile.Roles[?
                    (RoleName == \`\"${iamRoleName}\"\`)
                ].RoleName"
        )" ] && aws iam add-role-to-instance-profile \
            --instance-profile-name "${iamRoleName}" \
            --role-name "${iamRoleName}" \
            --no-cli-pager

        # Show IAM Instance Profile.
        aws iam get-instance-profile \
            --instance-profile-name "${iamRoleName}" \
            --output table --no-cli-pager

        # Create EC2 Instance.
        typeset ec2ID="$(
            typeset ec2Name="${_AWS__NET_PFX}--ec2--${_AWS__EC2__NAME_SFX}"
            typeset ec2ID="$(
                aws ec2 describe-instances \
                    --filters \
                        "Name=tag:Name,Values=${ec2Name}" \
                        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
                    --output text \
                    --query 'Reservations[0].Instances[0].InstanceId'
            )"
            if [ "${ec2ID}" = None ]; then
                aws ec2 run-instances \
                    --block-device-mappings '[{
                        "DeviceName": "/dev/xvda",
                        "Ebs": {
                            "DeleteOnTermination": true,
                            "VolumeType": "gp3",
                            "Encrypted": true,
                            "KmsKeyId": "alias/aws/ebs"
                        }
                    }]' \
                    --image-id "${amiID}" \
                    --instance-type "${_AWS__EC2__INST_TYPE}" \
                    --key-name "${_AWS__SSH_KEY__NAME}" \
                    --monitoring '{"Enabled": false}' \
                    --placement '{"Tenancy": "default"}' \
                    --credit-specification '{"CpuCredits": "unlimited"}' \
                    --hibernation-options '{"Configured": false}' \
                    --metadata-options '{
                        "HttpTokens": "required",
                        "HttpEndpoint": "enabled"
                    }' \
                    --private-dns-name-options '{
                        "HostnameType": "resource-name",
                        "EnableResourceNameDnsARecord": true,
                        "EnableResourceNameDnsAAAARecord": false
                    }' \
                    --maintenance-options '{"AutoRecovery": "default"}' \
                    --network-performance-options '{
                        "BandwidthWeighting": "default"
                    }' \
                    --instance-initiated-shutdown-behavior 'stop' \
                    --network-interfaces "$(
                        jq -cn \
                            --arg snID "${snID}" \
                            --arg sgID "${sgID}" \
                            '{
                                SubnetId: $snID,
                                AssociatePublicIpAddress: true,
                                DeviceIndex: 0,
                                Groups: [$sgID]
                            }'
                    )" \
                    --iam-instance-profile "Name=${iamRoleName}" \
                    --ebs-optimized \
                    --count 1 \
                    --tag-specifications "$(
                        yq -o json eval . 0<<<"${awsTagSpec}" | jq -c \
                            --arg ec2Name "${ec2Name}" \
                            --arg hddName "${ec2Name}--hdd--root" \
                            --arg nicName "${ec2Name}--nic--0" \
                            '[(
                                . |
                                .ResourceType="instance" |
                                .Tags[0].Value=$ec2Name
                            ), (
                                . |
                                .ResourceType="volume" |
                                .Tags[0].Value=$hddName
                            ), (
                                . |
                                .ResourceType="network-interface" |
                                .Tags[0].Value=$nicName
                            )]'
                    )" \
                    --output text \
                    --query 'Instances[0].InstanceId'
            else
                echo "${ec2ID}"
            fi
        )"; [ -n "${ec2ID}" ]

        # Set EC2 Instance Settings.
        aws ec2 modify-instance-attribute \
            --instance-id "${ec2ID}" \
            --disable-api-termination

        # Show EC2 Instance.
        aws ec2 describe-instances \
            --instance-ids "${ec2ID}" \
            --output table --no-cli-pager

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Preparing OS as VM Image Template</summary>

Run on VM.
<details><summary>Common</summary>

  - <details><summary>SSH Server</summary>

    ```shell
    sudo \
        bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
            typeset sshdCfg=/etc/ssh/sshd_config

            # Disallow `root` login.
            grep -q '^PermitRootLogin no' "${sshdCfg}" ||
                sed -i '/^#PermitRootLogin /a\
    PermitRootLogin no' "${sshdCfg}"

            # Reload SSHD configuration.
            systemctl reload sshd

            true
    cmdEOF
        )"; echo $?
    ```
    </details>
  - <details><summary>Default Applications</summary>

    ```shell
    sudo \
        bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
            typeset binArch="$(uname -m)"

            # Map `uname` architecture to Static release naming.
            case "${binArch}" in
              (x86_64)  binArch=amd64;;
              (aarch64) binArch=arm64;;
            esac

            # 1.  Install default applications.
            dnf install -y tmux tree

            # 2.  Install the extra utilities and applications.
            #   YAML Processor `yq`.
            (
                typeset binSrcName="yq_linux_${binArch}"
                wget -qO - "https://github.com/mikefarah/yq/releases/latest/download/${binSrcName}.tar.gz" |
                    tar zvx -C /usr/local/bin/ --transform "s|^\\./${binSrcName}\$|yq|" "./${binSrcName}"
            )

            #   BitWarden CLI (requires `node.js` 20+).
            dnf install -y nodejs24
            npm install -g @bitwarden/cli

            #   HashiCorp Vault CLI.
            (
                uid=992 gid="${uid}"
                getent group vault  || groupadd --system --gid "${gid}" vault
                getent passwd vault || useradd --system --uid "${uid}" --gid "${gid}" --home-dir / --no-create-home --shell /bin/false vault
                dnf config-manager --add-repo 'https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo'
                dnf config-manager --set-disabled hashicorp
                dnf install -y --enablerepo=hashicorp vault
                echo 'complete -C /usr/bin/vault vault' 1> /etc/bash_completion.d/vault
            )

            true
    cmdEOF
        )"; echo $?
    ```
    </details>
</details>
<details><summary>WebApp</summary>

  - <details><summary>Host FS</summary>

    ```shell
    sudo \
        bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
            typeset webAppDir=/opt/web-app

            mkdir -p "${webAppDir}"
            chmod 00755 "${webAppDir}"

            true
    cmdEOF
        )"; echo $?
    ```
    </details>
  - <details><summary>podman</summary>

    ```shell
    __SHELL=0 \
        bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
            ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

            sudo bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'sudoEOF'
                typeset binArch="$(uname -m)"

                # Map `uname` architecture to Static release naming.
                case "${binArch}" in
                  (x86_64)  binArch=amd64;;
                  (aarch64) binArch=arm64;;
                esac

                # Install required dependencies.
                dnf install -y iptables-nft nftables

                # Download and extract static Podman bundle.
                wget -qO - "https://github.com/mgoltzsche/podman-static/releases/latest/download/podman-linux-${binArch}.tar.gz" |
                    tar zvx -C / --strip-components=1 --exclude='README.md'
                mkdir -p /etc/bash_completion.d
                podman completion bash 1> /etc/bash_completion.d/podman

                # Configure system to allow unprivileged port binding.
                sysctl -w net.ipv4.ip_unprivileged_port_start=0
                cat - 0<<'cfgEOF' 1> /etc/sysctl.d/99-podman.conf
    # Allow unprivileged users to bind to privileged ports (< 1024).
    #   Required for rootless Podman to bind to ports 80, 443, etc.
    net.ipv4.ip_unprivileged_port_start=0
    cfgEOF

                # Create `podman--auto-update` timer for all users.
                mkdir -p /etc/systemd/user
                cat - 0<<'cfgEOF' 1> /etc/systemd/user/podman--auto-update.timer
    [Unit]
    Description=Podman auto-update timer

    [Timer]
    OnCalendar=daily
    Persistent=true

    [Install]
    WantedBy=timers.target
    cfgEOF
                # Create `podman--auto-update` service for all users.
                cat - 0<<'cfgEOF' 1> /etc/systemd/user/podman--auto-update.service
    [Unit]
    Description=Podman auto-update service

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/podman auto-update
    cfgEOF

                true
    sudoEOF
            )"

            systemctl --user daemon-reload
            systemctl --user enable podman--auto-update.timer

            true
    cmdEOF
        )"; echo $?
    ```
    </details>
  - <details><summary>SQLite</summary>

    ```shell
    sudo \
        bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
            dnf install -y sqlite   # Install SQLite3 CLI tool.
            true
    cmdEOF
        )"; echo $?
    ```
    </details>
</details>
</details>


### Generating AMI
<details><summary>SysPrep</summary>

Run on VM.

```shell
sudo \
    _JOB__SPARSE_IMG=0 \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
: '--- Cleaning Package Manager. ---'
dnf -y remove --oldinstallonly --setopt installonly_limit=2 || true
dnf -y autoremove
dnf clean all

: '--- Removing `cloud-init` cache to force new instance to re-run it. ---'
rm -rf /var/lib/cloud/*
echo 'localhost' > /etc/hostname

: '--- Removing SSH Host Keys. ---'
rm -f /etc/ssh/ssh_host_*_key
rm -f /etc/ssh/ssh_host_*_key.pub

: '--- Removing Root and Default User SSH directory. ---'
rm -rf /root/.ssh/
rm -rf "$(getent passwd 1000 | cut -d: -f6)/.ssh/"

: '--- Removing non-Default Users. ---'
awk -F: '(($3 >= 1001) && ($1 != "nobody")){print $1}' /etc/passwd | \
    xargs -r userdel -r

: '--- Removing non-Default Groups. ---'
awk -F: '(($3 >= 1001) && ($1 != "nobody")){print $1}' /etc/group | \
    xargs -r groupdel

: '--- Removing Default User & Group. ---'
chown -R 1001:1001 {/home,/var/spool/mail}/"$(id -nu 1000)"
sed -E -i 's/^(([^:]*:){2})1000:1000:/\11001:1001:/' /etc/passwd
sed -E -i 's/^(([^:]*:){2})1000:/\11001:/' /etc/group
userdel -r "$(id -nu 1001)"

: '--- Clearing `machine-id` for unique Instance Identity. ---'
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

: '--- Removing Random Seed. ---'
rm -f /var/lib/systemd/random-seed

: '--- Removing Temporary Files. ---'
rm -rf /tmp/*
rm -rf /var/tmp/*

: '--- Cleaning up Log Files. ---'
find /var/log -type f \( \
    -name '*.log.*' -o \
    -name '*.gz' -o \
    -name '*.bz2' -o \
    -name '*.xz' \
\) -delete
find /var/log -type f -name '*.log' -exec truncate -s 0 '{}' \;

: '--- Turning off Swap. ---'
swapoff -a || true

: '--- Zeroing Swap Partitions. ---'
((_JOB__SPARSE_IMG)) && (
    # Zero only Disk-based Swap Partitions (skip RAM-based swap).
    for sd in $(
        blkid -t TYPE=swap -o device |
        grep -vE '/dev/(zram|loop)'
    ); do
        echo "Zeroing Swap Partition ${sd@Q}..."
        dd if=/dev/zero of="${sd}" bs=1M status=progress || true
    done
)

: '--- Zeroing Volumes. ---'
((_JOB__SPARSE_IMG)) && (
    # Get only Block Dev. Mount Points (excluding tmpfs, devtmpfs, etc.).
    while IFS= read -r mp; do
        echo "Zeroing free space on ${mp@Q}..."
        touch "${mp}/zerofile"
        chattr +C "${mp}/zerofile" 2> /dev/null || true
        dd if=/dev/zero of="${mp}/zerofile" bs=1M conv=fsync status=progress || true
        rm -f "${mp}/zerofile"
    done 0< <(
        # FS without sub-vol.
        df -t ext4 -t xfs -t vfat --output=target |
        tail -n +2
        # B-Tree FS: pick the least quota-restricted sub-vol. per dev.
        df -t btrfs --output=source,avail,target |
        tail -n +2 |
        sed -E 's/  */\t/; s/  */\t/' |
        sort -t $'\t' -k 1,1 -k 2,2rn |
        awk -F '\t' '!seen[$1]++ {print $3}'
    )
)

: '--- Cleaning up `systemd journal` Logs. ---'
journalctl --rotate
journalctl --vacuum-time=1s

: '--- Cleanup complete. Shutting down. ---'
shutdown now
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Creating AMI</summary>

```shell
__SHELL=0 \
    _AWS__NET_PFX='...netPfx..' \
    _AWS__APP_KIND='...appKind...' \
    _AWS__EC2__NAME_SFX="ami--generator" \
    _AWS__EC2__TO_SHUTDOWN=600s \
    _AWS__EC2__AMI_NAME='...ec2AMIname..' \
    _AWS__EC2__AMI_DESC='OS Image for generic Server (Amazon Linux 2023 - ARM64).' \
    _AWS__RESET_PROFILE=0 \
    _AWS__PROFILE=ocp \
    _AWS__ROLE_NAME_SFX=poweruser \
   x_AWS__SES_TO=3600 \
    AWS_REGION=us-west-1 \
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
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this \`DEBUG\` session!!!

        typeset ec2Name="${_AWS__NET_PFX}--ec2--${_AWS__EC2__NAME_SFX}"

        typeset ec2ID="$(
            aws ec2 describe-instances \
                --filters \
                    "Name=tag:Name,Values=${ec2Name}" \
                    "Name=instance-state-name,Values=stopped,stopping" \
                --output text \
                --query 'Reservations[0].Instances[0].InstanceId'
        )"; [ -n "${ec2ID}" ]

        # Ensure the EC2 Instance is completely stopped.
        #   use `bash` wrapper to expand the `aws()` (because it is exported).
        timeout "${_AWS__EC2__TO_SHUTDOWN}" \
            bash -uxc "aws ec2 wait instance-stopped --instance-ids ${ec2ID@Q}"

        # Create encrypted AMI from stopped instance.
        typeset amiID="$(
            aws ec2 create-image \
                --instance-id "${ec2ID}" \
                --name "${_AWS__EC2__AMI_NAME}" \
                --description "${_AWS__EC2__AMI_DESC}" \
                --no-reboot \
                --block-device-mappings '[{
                    "DeviceName": "/dev/xvda",
                    "Ebs": {"Encrypted": true}
                }]' \
                --tag-specifications "$(
                    jq -cn \
                        --arg name "${_AWS__EC2__AMI_NAME}" \
                        '[{
                            ResourceType: "image",
                            Tags: [{Key: "Name", Value: $name}]
                        }]'
                )" \
                --output text \
                --query 'ImageId'
        )"; [ -n "${amiID}" ]

        # Wait for AMI to become available.
        aws ec2 wait image-available --image-ids "${amiID}"

        # Show created AMI.
        aws ec2 describe-images --image-ids "${amiID}" \
            --output table --no-cli-pager

        true
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Destroying AMI Generator VM</summary>

```shell
__SHELL=0 \
    _AWS__NET_PFX='...netPfx..' \
    _AWS__EC2__NAME_SFX="ami--generator" \
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

        typeset ec2Name="${_AWS__NET_PFX}--ec2--${_AWS__EC2__NAME_SFX}"

        typeset ec2ID="$(
            aws ec2 describe-instances \
                --filters \
                    "Name=tag:Name,Values=${ec2Name}" \
                    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
                --output text \
                --query 'Reservations[0].Instances[0].InstanceId'
        )"; [ -n "${ec2ID}" ]

        # Disable stop protection.
        aws ec2 modify-instance-attribute \
            --instance-id "${ec2ID}" \
            --no-disable-api-stop

        # Stop EC2 Instance.
        aws ec2 stop-instances --instance-ids "${ec2ID}" --no-cli-pager
        aws ec2 wait instance-stopped --instance-ids "${ec2ID}"

        # Disable termination protection.
        aws ec2 modify-instance-attribute \
            --instance-id "${ec2ID}" \
            --no-disable-api-termination

        # Terminate EC2 Instance.
        aws ec2 terminate-instances --instance-ids "${ec2ID}" --no-cli-pager
        aws ec2 wait instance-terminated --instance-ids "${ec2ID}"

        true
cmdEOF
    )"; echo $?
```
</details>



## Deleting VM Instance
### Deleting VM
<details><summary>Terminating EC2 Instance</summary>

```shell
__SHELL=0 \
    _AWS__NET_PFX='...netPfx..' \
    _AWS__APP_KIND='...appKind...' \
    _AWS__EC2__NAME_SFX="${_AWS__APP_KIND}--host" \
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

        typeset ec2Name="${_AWS__NET_PFX}--ec2--${_AWS__EC2__NAME_SFX}"

        typeset ec2ID="$(
            aws ec2 describe-instances \
                --filters \
                    "Name=tag:Name,Values=${ec2Name}" \
                    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
                --output text \
                --query 'Reservations[0].Instances[0].InstanceId'
        )"; [ -n "${ec2ID}" ]

        # Disable termination protection.
        aws ec2 modify-instance-attribute \
            --instance-id "${ec2ID}" \
            --no-disable-api-termination

        # Terminate EC2 Instance.
        aws ec2 terminate-instances --instance-ids "${ec2ID}" --no-cli-pager
        aws ec2 wait instance-terminated --instance-ids "${ec2ID}"

        true
cmdEOF
    )"; echo $?
```
</details>

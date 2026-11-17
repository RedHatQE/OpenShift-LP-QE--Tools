# Setting Up Chisel (Containerized)
##  Installation (using NGINX).
**Pre-requisites:**
  - **(BitWarden):** Note `_BW__NOTE_NAME` must have a custom field `_BW__NOTE_SUB_FLD` whose value is a JSON string containing at least:
    ```json
    {"usr": "...usrName...", "pwd": "...usrPass...", "aclRgx": ["...aclRgx1..."]}
    ```
  - **(NGINX):** `svc--nginx` container running on Container Network `net--web-app` per
    [NGINX SettingUp](../NGINX/SettingUp.md).
<details><summary>Preparing Host</summary>

```shell
__SHELL=0 __DBG=0 \
    _SVC__FQDN='...svcFQDN...' \
    _SVC__PORT__CP="${_SVC__PORT__CP:-5050}" \
    _SVC__PORT__DP_RGX="${_SVC__PORT__DP_RGX:-(?:[2-9]\d{3}|[12]\d{4})}" \
    _SVC__ADM_EML='...svcAdmEMail...' \
    _SVC__OWN_DATA_DIR=/opt/web-app/chisel \
    _SVC__RPX_NAME=nginx \
    _SVC__RPX_CFG_DIR="/opt/web-app/${_SVC__RPX_NAME}" \
    _BW__NOTE_SUB_FLD='cred.defAdm' \
    _BW__NOTE_NAME='...bwNoteName...' \
    BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}" \
    BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)" \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
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
                        (
                            "typeset -x " +
                            "svcAdmUsr=\(.usr | @sh) " +
                            "svcAdmPwd=\(.pwd | @sh) " +
                            "svcAdmAclRgx=\((.aclRgx // []) | tojson | @sh)"
                        )
                    ' \
                0<<<"${bwData}"
            )"
            eval "${__shOpt}"; unset __shOpt
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset ownUsr="$(id -un)"
        typeset ownGrp=web-app
        typeset ctrNet=net--web-app
        typeset svcCtrName=svc--chisel
        typeset svcConfDir=/etc/chisel
        typeset svcUsrDB="${_SVC__OWN_DATA_DIR}${svcConfDir}/users.json"
        typeset rpxCtrName="svc--${_SVC__RPX_NAME}"
        typeset rpxSvcConf="${_SVC__RPX_CFG_DIR}/etc/nginx/conf.d/chisel.conf"
        typeset certsDir="${_SVC__RPX_CFG_DIR}/etc/nginx/certs"
        typeset certbotDir="${_SVC__RPX_CFG_DIR}/var/www/certbot"
        typeset quadletUsrDir="${HOME}/.config/containers/systemd"
        typeset systemdSvcName=container--chisel
        typeset +x svcAdmUsr svcAdmPwd svcAdmAclRgx

        ((__DBG)) && {
            podman container run \
                --name "${svcCtrName}" \
                --rm -it \
                --network "${ctrNet}" \
                -v "${_SVC__OWN_DATA_DIR}${svcConfDir}:${svcConfDir}:Z" \
                docker.io/jpillora/chisel:latest \
                server \
                    --port "${_SVC__PORT__CP}" \
                    --authfile "${svcConfDir}/users.json" \
                    --reverse
            exit 0
        }

        function ReloadRPXsvc () {
            typeset rpxCtrName="${1}"; (($#)) && shift

            [ "$(podman container inspect "${rpxCtrName}" --format '{{.State.Status}}')" = running ]
            podman container exec "${rpxCtrName}" "${_SVC__RPX_NAME}" -t
            podman container exec "${rpxCtrName}" "${_SVC__RPX_NAME}" -s reload

            true
        }

        sudo bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<sudoEOF
            # Prepare Directories.
            mkdir -p ${_SVC__OWN_DATA_DIR@Q}${svcConfDir@Q}
            chown -R ${ownUsr@Q}:${ownGrp@Q} ${_SVC__OWN_DATA_DIR@Q}/
            chmod -R 02775 ${_SVC__OWN_DATA_DIR@Q}/
            setfacl \
                -Rm g::rwx,m::rwx,d:g::rwx,d:m::rwx \
                ${_SVC__OWN_DATA_DIR@Q}/

            true
sudoEOF
        )"

        # Create minimal HTTP-only configuration for ACME challenge.
        # Note: NGINX container sees this because
        #   `-v ${_SVC__RPX_CFG_DIR}/conf.d:/etc/nginx/conf.d` mounts the
        #   directory, so any file changes on host are visible in container.
        cat - 0<<cfgEOF 1> "${rpxSvcConf}"
# NGINX Chisel Configuration File (Minimal - HTTP Only for ACME Challenge)

server {
    listen 0.0.0.0:80;
    listen [::]:80;

    server_name ${_SVC__FQDN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 503;
    }
}
cfgEOF
        # Reload NGINX to pick up minimal config.
        ReloadRPXsvc "${rpxCtrName}"

        # Request Let's Encrypt certificate using Certbot (webroot method).
        # Certbot stores certificates in `/etc/letsencrypt/live/${_SVC__FQDN}/`
        #   on host.
        sudo certbot certonly \
            --webroot \
            --webroot-path "${certbotDir}" \
            --domain "${_SVC__FQDN}" \
            --non-interactive \
            --agree-tos \
            --email "${_SVC__ADM_EML}" \
            --keep-until-expiring

        # Create Certbot Deploy Hook.
        sudo bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<sudoEOF
            mkdir -p /etc/letsencrypt/renewal-hooks/deploy
            cat - 0<<'scrEOF' 1> /etc/letsencrypt/renewal-hooks/deploy/${_SVC__FQDN@Q}.sh
#!/bin/bash
set -euo pipefail; shopt -s inherit_errexit
# Copy certificates to NGINX certs directory.
cp -f \\
    /etc/letsencrypt/live/${_SVC__FQDN@Q}/privkey.pem \\
    ${certsDir@Q}/chisel.key
cp -f \\
    /etc/letsencrypt/live/${_SVC__FQDN@Q}/fullchain.pem \\
    ${certsDir@Q}/chisel.crt
chown ${ownUsr@Q}:${ownGrp@Q} ${certsDir@Q}/chisel.{key,crt}
chmod 00600 ${certsDir@Q}/chisel.key
chmod 00644 ${certsDir@Q}/chisel.crt
# Reload NGINX.
runuser -u ${ownUsr@Q} -- podman container exec ${rpxCtrName@Q} nginx -s reload
scrEOF
            chmod 00755 /etc/letsencrypt/renewal-hooks/deploy/${_SVC__FQDN@Q}.sh

            # Execute for initial certificates.
            /etc/letsencrypt/renewal-hooks/deploy/${_SVC__FQDN@Q}.sh
            # Enable renewal timer.
            systemctl enable --now certbot-renew.timer

            true
sudoEOF
        )"

        # Create full configuration file with HTTPS.
        cat /dev/fd/{3..11} \
            3<<'cfgEOF' 4<<cfgEOF \
            5<<'cfgEOF' 6<<cfgEOF \
            7<<'cfgEOF' 8<<cfgEOF \
            9<<'cfgEOF' 10<<cfgEOF \
            11<<'cfgEOF' 1> "${rpxSvcConf}"
# NGINX Chisel Configuration File

# ==============================================================================
# 1.  HTTP Block (Port 80)
#     Handles ACME Challenges & redirects to HTTPS.
# ==============================================================================
server {
    listen 0.0.0.0:80;
    listen [::]:80;

    server_name
cfgEOF
        ${_SVC__FQDN}
cfgEOF
    ;

    # --------------------------------------------------------------------------
    # ACME Challenge Location
    # --------------------------------------------------------------------------
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # --------------------------------------------------------------------------
    # HTTPS Redirect
    # --------------------------------------------------------------------------
    location / {
        return 301 https://${host}${request_uri};
    }
}

# ==============================================================================
# 2.  HTTPS Block (Port 443)
#     Control Plane (`/cp/`):           WebSocket proxy to Chisel Container.
#     Data Plane (`/dp/<ctrPort>/`):    HTTP proxy to Reverse-Tunneled Service.
# ==============================================================================
server {
    listen 0.0.0.0:443 ssl;
    listen [::]:443 ssl;
    # The `http2` parameter is deprecated in newer NGINX versions, usually
    #   enabled automatically or via 'http2 on;' directive.
    # If using older NGINX (pre-1.25.1), use `listen 0.0.0.0:443 ssl http2;`.
    http2 on;

    server_name
cfgEOF
        ${_SVC__FQDN}
cfgEOF
    ;

    # --------------------------------------------------------------------------
    # SSL Certificates
    # --------------------------------------------------------------------------
    ssl_certificate     /etc/nginx/certs/chisel.crt;
    ssl_certificate_key /etc/nginx/certs/chisel.key;

    # --------------------------------------------------------------------------
    # Control Plane
    # Accepts `https://` (WebSocket over TLS) from Chisel Clients.
    # NGINX terminates TLS and forwards as plain `ws://` to Chisel Container.
    # Whole Path with prefix `/cp/` is completely removed and replaced with
    #   `/` (via trailing `/` while using var. in `proxy_pass`).
    # --------------------------------------------------------------------------
    location /cp/ {
cfgEOF
        # Use variable to force dynamic DNS resolution via resolver directive.
        #   The \`${svcCtrName}\` is the container name on the \`${ctrNet}\`
        #   Podman Network.
        set \$svcBackEndCP ${svcCtrName}:${_SVC__PORT__CP};
cfgEOF
        proxy_pass http://${svcBackEndCP}/;

        # WebSocket upgrade: convert `https://` (client) to `ws://` (chisel).
        proxy_http_version 1.1;
        proxy_set_header Upgrade ${http_upgrade};
        proxy_set_header Connection 'upgrade';

        proxy_set_header Host ${host};
        proxy_set_header X-Real-IP ${remote_addr};
        proxy_set_header X-Forwarded-For ${proxy_add_x_forwarded_for};
        proxy_set_header X-Forwarded-Proto ${scheme};

        # Long timeouts: Chisel Control Connection is persistent.
        proxy_connect_timeout 7d;
        proxy_send_timeout 7d;
        proxy_read_timeout 7d;
    }

    # --------------------------------------------------------------------------
    # Data Plane
    # HTTP access to the service exposed by Chisel Reverse Tunnel.
    # Container port is embedded in URL path `/dp/<ctrPort>/`, restricted to
    #   `_SVC__PORT__DP_RGX`. Path remainder is forwarded to Chisel container.
    # --------------------------------------------------------------------------
cfgEOF
    location ~ "^/dp/(${_SVC__PORT__DP_RGX})/(.*)$" {
        # \$1:   The `ctrPort` (from URL Path)
        # \$2:   The remainder of the Path.
        # The \`${svcCtrName}\` is the container name on the \`${ctrNet}\`
        #   Podman Network.
        set \$svcBackEndDP ${svcCtrName}:\$1;
cfgEOF
        proxy_pass http://$svcBackEndDP/$2;

        proxy_set_header Host ${host};
        proxy_set_header X-Real-IP ${remote_addr};
        proxy_set_header X-Forwarded-For ${proxy_add_x_forwarded_for};
        proxy_set_header X-Forwarded-Proto ${scheme};

        # No buffering: pass data through immediately.
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
    }
}
cfgEOF

        # Create or update default Administrator entry in Chisel AuthFile.
        [ -f "${svcUsrDB}" ] || echo '{}' 1> "${svcUsrDB}"
        exec 3< <(0< "${svcUsrDB}"); wait $!
        jq \
            --rawfile usr <(set +x; printf '%s' "${svcAdmUsr}") \
            --rawfile pwd <(set +x; printf '%s' "${svcAdmPwd}") \
            --argjson aclRgx "${svcAdmAclRgx}" \
            '
                with_entries(
                    select(.key | startswith("\($usr):") | not)
                ) + {"\($usr):\($pwd)": $aclRgx}
            ' \
        0<&3 1> "${svcUsrDB}"
        exec 3<&-
        chmod 00600 "${svcUsrDB}"

        # Create Podman Network.
        podman network create "${ctrNet}" 2> /dev/null || true
        # Create Quadlet container file.
        mkdir -p "${quadletUsrDir}"
        cat - 0<<cfgEOF 1> "${quadletUsrDir}/${systemdSvcName}.container"
[Unit]
Description=Chisel Tunnel Service
After=network-online.target

[Container]
Image=docker.io/jpillora/chisel:latest
ContainerName=${svcCtrName}
AutoUpdate=registry
Network=${ctrNet}
Exec=server \\
    --port ${_SVC__PORT__CP} \\
    --authfile ${svcConfDir}/users.json \\
    --reverse
Volume=${_SVC__OWN_DATA_DIR}${svcConfDir}:${svcConfDir}:Z

[Service]
Restart=always

[Install]
WantedBy=default.target
cfgEOF
        # Reload and start the service.
        systemctl --user daemon-reload  # Quadlet will generate unit file.
        if systemctl --user is-active "${systemdSvcName}.service" &> /dev/null; then
            systemctl --user restart "${systemdSvcName}.service"
        else
            systemctl --user start "${systemdSvcName}.service"
        fi
        systemctl --user is-enabled podman--auto-update.timer &> /dev/null ||
            systemctl --user enable --now podman--auto-update.timer
        # Reload NGINX to apply full configuration with HTTPS.
        ReloadRPXsvc "${rpxCtrName}"

        true
cmdEOF
    )"; echo $?
```
</details>


## Administrative Tasks
<details><summary>Managing Credentials</summary>

```shell
#   The `_SVC__ACTION` absolute value is a bit flag for which information need
#   to be updated (while the pos. sign means create or update and neg. sign
#   means delete).
#     0x01  User Password.
#     0x02  User ACL.
__SHELL=0 \
    _SVC__ACTION=1 \
    _SVC__CRD_USR='...chiselCrdUsr...' \
    _SVC__CRD_PWD_CHG=0 \
    _SVC__ACL_RGX="${_SVC__ACL_RGX:-('^R:0\.0\.0\.0:8443$')}" \
    _SVC__OWN_DATA_DIR=/opt/web-app/chisel \
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
   xVAULT_ADDR='...vaultAddr...' \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        {
            typeset __shOpt="$(shopt -po xtrace)"; set +x
            [ -n "${BW_SESSION}" ] && bw sync || {
                echo 'You do NOT have an active and sync:ed BitWarden Session!!!' 1>&2
                exit 1
            }
            eval "${__shOpt}"; unset __shOpt
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset svcConfDir=/etc/chisel
        typeset svcUsrDB="${_SVC__OWN_DATA_DIR}${svcConfDir}/users.json"
        typeset systemdSvcName=container--chisel
        typeset bwData= bwSubFld="cred.${_SVC__CRD_USR}"
        typeset crdPwd= aclRgxJSON=
        typeset -i absAction="$((
            (_SVC__ACTION < 0) ? -_SVC__ACTION : _SVC__ACTION
        ))"
        typeset -a aclRgx="${_SVC__ACL_RGX}"

        case ${_SVC__ACTION} in
            (-[123]|[123])  [ -n "${_BW__NOTE_NAME}" ];;
            (0)             ;;
            (*)             false;;
        esac

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

        [ -f "${svcUsrDB}" ] || echo '{}' 1> "${svcUsrDB}"
        exec 3< <(0< "${svcUsrDB}"); wait $!
        case ${_SVC__ACTION} in
          (-3|-1)
            # Delete Credential.
            jq \
                --arg usr "${_SVC__CRD_USR}" \
                'with_entries(select(.key | startswith("\($usr):") | not))' \
            0<&3 1> "${svcUsrDB}"
            ;;
          (-2|1|2|3)
            typeset __shOpt="$(shopt -po xtrace)"; set +x
            # Password handling.
            crdPwd="$( set +x
                ((absAction & 0x01)) || {
                    crdPwd="$(jq -cr \
                        --arg usr "${_SVC__CRD_USR}" \
                        '
                            to_entries[] |
                            select(.key | startswith("\($usr):")) |
                            .key |
                            ltrimstr("\($usr):")
                        ' \
                    0< "${svcUsrDB}")"
                    [ -z "${crdPwd}" ] && {
                        echo "[${svcUsrDB}] User not found: ${_SVC__CRD_USR}" 1>&2
                        exit 1
                    } || echo "${crdPwd}"
                exit 0
                }
                ((_SVC__CRD_PWD_CHG)) || {
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
            true )"
            # Build ACL.
            aclRgxJSON="$(jq -cn --args '$ARGS.positional' "${aclRgx[@]}")"
            aclRgxJSON="$(jq -c \
                --arg usr "${_SVC__CRD_USR}" \
                --argjson inLst "$(
                    ((absAction & 0x02)) && echo "${aclRgxJSON}" || echo '[]'
                )" \
                --argjson add "$(((_SVC__ACTION > 0) ? 1 : 0))" \
                '([
                    to_entries[] |
                    select(.key | startswith("\($usr):")) |
                    .value
                ][0] // []) as $acl | (
                    if ($add == 1) then (($acl + $inLst) | unique)
                    else ($acl - $inLst)
                    end
                )' \
            0< "${svcUsrDB}")"
            # Update User DataBase.
            jq \
                --arg usr "${_SVC__CRD_USR}" \
                --arg pwd "${crdPwd}" \
                --argjson aclRgx "${aclRgxJSON}" \
                '
                    with_entries(select(.key | startswith("\($usr):") | not)) +
                    {"\($usr):\($pwd)": $aclRgx}
                ' \
            0<&3 1> "${svcUsrDB}"
            eval "${__shOpt}"; unset __shOpt
            ;;
        esac
        exec 3<&-
        chmod 00600 "${svcUsrDB}"
        # Restart the Service.
        case ${_SVC__ACTION} in
          (-[123]|[123])    systemctl --user restart "${systemdSvcName}.service";;
        esac

        # List all Users.
        jq -r '(
            "List of Users:",
            (to_entries[] | (
                "    \(.key | split(":")[0]):",
                (.value[] | "        \(.)")
            ))
        )' "${svcUsrDB}"

        # Update BitWarden.
        [ -z "${_BW__NOTE_NAME}" ] || ( set +x
            case ${_SVC__ACTION} in
              (-3|-1)
                bwData="$(jq -r \
                    --arg fn__c "${bwSubFld}" \
                    '.fields|=map(select(.name != $fn__c))' \
                0<<<"${bwData}")"
                bw encode 0<<<"${bwData}" | bw edit item "$(jq -cr '.id' 0<<<"${bwData}")" 1> /dev/null
                ;;
              (-2|1|2|3)
                bwData="$(jq -r \
                    --arg fn__c "${bwSubFld}" \
                    --rawfile fv__c <( set +x
                        jq -cnj \
                            --arg usr "${_SVC__CRD_USR}" \
                            --arg pwd "${crdPwd}" \
                            --argjson aclRgx "${aclRgxJSON}" \
                            '{usr: $usr, pwd: $pwd, aclRgx: $aclRgx}'
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
        ] || (( ! (absAction & 0x01) )) || ( set +x
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

            typeset gsmSecPathUsr= gsmSecPathPwd= gsmSecLst= e=
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

            case ${_SVC__ACTION} in
              (-3|-1)
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
              (1|3)
                for e in Usr Pwd; do
                    typeset -n gsmSecItemRef="gsmSecPath${e}"
                    typeset -n gsmSecFlagRef="gsmSecExist${e}"
                    if [ "${e}" = 'Usr' ]; then
                        _GSM__SEC_VAL="${_SVC__CRD_USR}"
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
#       ] || (( ! (absAction & 0x01) )) || ( set +x
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
#           case ${_SVC__ACTION} in
#             (-3|-1)
#               {
#                   jq -r \
#                       --arg ku "${_VAULT_KEY_USR}" \
#                       --arg kp "${_VAULT_KEY_PWD}" \
#                       '.data.data | del(.[$ku], .[$kp])' \
#                   0<<<"${vaultData}" |
#                   vault kv put -mount="${_VAULT_MOUNT}" "${_VAULT_KEY_PATH}" - 1> /dev/null
#               } || true   # Ignore error (may not have delete permission).
#               ;;
#             (1|3)
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
#                       --arg ku "${_SVC__CRD_USR}" \
#                       --arg kp "${crdPwd}" \
#                       '{u: $ku, p: $kp}'
#               )" ] || {
#                   vault kv destroy -mount="${_VAULT_MOUNT}" -versions="$(
#                       jq -r '.data.metadata.version' 0<<<"${vaultData}"
#                   )" "${_VAULT_KEY_PATH}" &> /dev/null || true    # Ignore error (may not have delete permission).
#                   {
#                       jq -r \
#                           --arg ku "${_VAULT_KEY_USR}" \
#                           --arg vu "${_SVC__CRD_USR}" \
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


## Operational Tasks
<details><summary>Connect Chisel Client</summary>

```shell
( set -euo pipefail; shopt -s inherit_errexit
    typeset svcFQDN='...svcFQDN...'
    typeset -i svcDPport=8443   # Any port matching Server `_SVC__PORT__DP_RGX`.
    typeset -i localPort=8080   # Local service port on this machine.

    # Start Chisel Client (connect to control plane and set up reverse tunnel).
    #   R:0.0.0.0:<svcDPport>:localhost:<localPort>
    #       Chisel Server binds `<svcDPport>` on all interfaces.
    #       Incoming connections on Chisel Server are forwarded to
    #           `localhost:<localPort>` on Chisel Client's system.
    chisel client \
        "https://${svcFQDN}/cp/" \
        "R:0.0.0.0:${svcDPport}:localhost:${localPort}"
true ); echo $?
```
**Notes:**
  - The `https://` scheme uses the standard HTTPS port (443). No port number
    needed in the URL: NGINX listens on 443 and routes `/cp/` to Chisel.
  - The `<svcDPport>` must match `_SVC__PORT__DP_RGX` on the Server. NGINX
    routes `/dp/<svcDPport>/` to `svc--chisel:<svcDPport>`. If the port is
    already in use (another session), pick a different port in the allowed
    range.
  - The reverse tunnel binds `0.0.0.0` so Chisel Container itself can accept
    connections from NGINX (same Podman network, no host port publishing).
</details>
<details><summary>Access Tunneled Service (Data Plane)</summary>

Once a Chisel Client has established a reverse tunnel:
```shell
( set -euo pipefail; shopt -s inherit_errexit
    typeset svcFQDN='...svcFQDN...'
    typeset -i svcDPport=8443   # Must match the port used by the Chisel Client.

    # Example: retrieve a file from the tunneled Python HTTP Server.
    curl -fsSL "https://${svcFQDN}/dp/${svcDPport}/path/to/file"
true ); echo $?
```
**Notes:**
  - The `/dp/<port>/` prefix is stripped by NGINX before forwarding. A request
    to `https://<svcFQDN>/dp/<port>/foo` reaches the upstream service as
    `/foo`.
  - TLS terminates at NGINX. The tunneled service does not need TLS.
</details>


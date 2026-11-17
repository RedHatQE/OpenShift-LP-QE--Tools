# Setting Up Grafana (Containerized)
##  Installation (using NGINX).
**Pre-requisites:**
  - **(GCP Console):** Configure the GCP OAuth2 Client in the [Google Cloud Console](https://console.cloud.google.com/apis/credentials):
      - Add the root domain of `_SVC__FQDN` to the OAuth Consent Screen **Authorized Domains**.
      - Add the **Authorized Redirect URI**: `https://<_SVC__FQDN>/login/google`
  - **(BitWarden):** Note `_BW__NOTE_NAME` must have a custom field `_BW__NOTE_SUB_FLD` whose value is a JSON string containing at least:
    ```json
    {
        "web": {
            "client_id": "...clientID...",
            "client_secret": "...clientToken..."
        }
    }
    ```
  - **(NGINX):** `svc--nginx` container running on Container Network `net--web-app` per
    [NGINX SettingUp](../NGINX/SettingUp.md).
<details><summary>Preparing Host</summary>

```shell
__SHELL=0 __DBG=0 \
    _SVC__FQDN='...svcFQDN...' \
    _SVC__ADM_EML='...svcAdmEMail...' \
    _SVC__ADM_USR=redhat \
    _SVC__OWN_DATA_DIR=/opt/web-app/grafana \
    _SVC__RPX_NAME=nginx \
    _SVC__RPX_CFG_DIR="/opt/web-app/${_SVC__RPX_NAME}" \
    _BW__NOTE_SUB_FLD='oAuth.Grafana' \
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
                        .web | "
                            export _GCP__OAUTH_CLIENT_ID=\(.client_id | @sh) _GCP__OAUTH_CLIENT_SECRET=\(.client_secret | @sh)
                        "
                    ' \
                0<<<"${bwData}"
            )"
            eval "${__shOpt}"; unset __shOpt
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset ownUsr="$(id -un)"
        typeset ownGrp=web-app
        typeset ctrNet=net--web-app
        typeset svcCtrName=svc--grafana
        typeset svcConfDir=/etc/grafana
        typeset svcDataDir=/var/lib/grafana
        typeset svcSMTP=svc--postfix:25
        typeset gfProvPath="${svcConfDir}/provisioning"
        typeset gfProvDir="$(
            [ "${gfProvPath:0:1}" == / ] &&
                echo "${gfProvPath}" ||
                echo "${GF_PATHS_HOME:-.}/${gfProvPath}"
        )"
        typeset rpxCtrName="svc--${_SVC__RPX_NAME}"
        typeset rpxSvcConf="${_SVC__RPX_CFG_DIR}/etc/nginx/conf.d/grafana.conf"
        typeset certsDir="${_SVC__RPX_CFG_DIR}/etc/nginx/certs"
        typeset certbotDir="${_SVC__RPX_CFG_DIR}/var/www/certbot"
        typeset quadletUsrDir="${HOME}/.config/containers/systemd"
        typeset systemdSvcName=container--grafana

        ((__DBG)) && {
            podman container run \
                --name "${svcCtrName}" \
                --rm -it \
                --network "${ctrNet}" \
                --user 500 \
                --userns keep-id:uid=500 \
                -v "${_SVC__OWN_DATA_DIR}${svcConfDir}:${svcConfDir}:ro,Z" \
                -v "${_SVC__OWN_DATA_DIR}${svcDataDir}:${svcDataDir}:Z" \
                docker.io/grafana/grafana:latest
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
            mkdir -p ${_SVC__OWN_DATA_DIR@Q}\
{${svcConfDir@Q},${svcDataDir@Q},\
${gfProvDir@Q}/{alerting,dashboards,datasources,plugins}\
}
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
# NGINX Grafana Configuration File (Minimal - HTTP Only for ACME Challenge)

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
    ${certsDir@Q}/grafana.key
cp -f \\
    /etc/letsencrypt/live/${_SVC__FQDN@Q}/fullchain.pem \\
    ${certsDir@Q}/grafana.crt
chown ${ownUsr@Q}:${ownGrp@Q} ${certsDir@Q}/grafana.{key,crt}
chmod 00600 ${certsDir@Q}/grafana.key
chmod 00644 ${certsDir@Q}/grafana.crt
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
        cat /dev/fd/{3..9} \
            3<<'cfgEOF' 4<<cfgEOF \
            5<<'cfgEOF' 6<<cfgEOF \
            7<<'cfgEOF' 8<<cfgEOF \
            9<<'cfgEOF' 1> "${rpxSvcConf}"
# NGINX Grafana Configuration File

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
    # This block allows Certbot to verify domain ownership via HTTP (Port 80).
    # You must map a host directory (e.g., `/opt/web-app/nginx/certbot`) to
    #   `/var/www/certbot` inside the container for this to work.
    # --------------------------------------------------------------------------
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;  # Certbot expects to find files here.
    }

    # --------------------------------------------------------------------------
    # HTTPS Redirect
    # All other traffic is redirected to the secure HTTPS port.
    # --------------------------------------------------------------------------
    location / {
        return 301 https://${host}${request_uri};   # Force permanent redirect to HTTPS.
    }
}

# ==============================================================================
# 2.    HTTPS Block (Port 443)
#       Proxies traffic to the Grafana Container.
# ==============================================================================
server {
    listen 0.0.0.0:443 ssl;
    listen [::]:443 ssl;
    # The `http2` parameter is deprecated in newer NGINX versions, usually
    #   enabled automatically or via 'http2 on;' directive.
    # If using older NGINX (pre-1.25.1), use `listen 0.0.0.0:443 ssl http2;`.
    http2 on;   # Enable HTTP/2 for faster client connections.

    server_name
cfgEOF
        ${_SVC__FQDN}
cfgEOF
    ;

    client_max_body_size 50M;   # Upload limit (Grafana Dashboards/Plugins can be large).

    # --------------------------------------------------------------------------
    # SSL Certificates
    # Ensure these files exist on the Host and are mounted to these paths inside
    #   the Container FS.
    # --------------------------------------------------------------------------
    ssl_certificate     /etc/nginx/certs/grafana.crt;
    ssl_certificate_key /etc/nginx/certs/grafana.key;

    # =================================================================
    # Proxy Configuration
    # =================================================================
    location / {
cfgEOF
        # Use variable to force dynamic DNS resolution via resolver directive.
        #   The \`${svcCtrName}\` is the container name on the \`${ctrNet}\`
        #   Podman Network.
        set \$svcBackEnd ${svcCtrName}:3000;
cfgEOF
        proxy_pass http://${svcBackEnd};

        # Proxy Headers for correct IP forwarding.
        proxy_set_header Host ${host};
        proxy_set_header X-Real-IP ${remote_addr};
        proxy_set_header X-Forwarded-For ${proxy_add_x_forwarded_for};
        proxy_set_header X-Forwarded-Proto ${scheme};

        # WebSocket Support (Required for Grafana Live).
        proxy_http_version 1.1;
        proxy_set_header Upgrade ${http_upgrade};
        proxy_set_header Connection 'upgrade';

        # Timeouts (optional tuning).
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
cfgEOF

        # Create Grafana Configuration File.
        cat - 0<<cfgEOF 1> "${_SVC__OWN_DATA_DIR}${svcConfDir}/grafana.ini"
# Grafana Configuration File

[paths]
;data = /var/lib/grafana                                    # From \`${GF_PATHS_DATA}\`.
;temp_data_lifetime = 24h
;logs = /var/log/grafana                                    # From \`${GF_PATHS_LOGS}\`.
;plugins = /var/lib/grafana/plugins                         # From \`${GF_PATHS_PLUGINS}\`.
;provisioning = /etc/grafana/provisioning                   # From \`${GF_PATHS_PROVISIONING}\`.
;permitted_provisioning_paths = devenv/dev-dashboards|conf/provisioning

[security]
admin_user = ${_SVC__ADM_USR}
# The \`admin_password\` intentionally not set (uses default \`admin\`).
#   Grafana will force the password change on first login.

[users]
allow_sign_up = false
auto_assign_org_role = Viewer

[server]
root_url = https://${_SVC__FQDN}

[smtp]
enabled = true
host = ${svcSMTP}
skip_verify = true
startTLS_policy = NoStartTLS
from_address = grafana@${_SVC__FQDN#*.*.}
from_name = Grafana

[auth]
oauth_allow_insecure_email_lookup = true                    # Allow linking exiting user with OAuth login.

[auth.anonymous]
enabled = false

[auth.google]
enabled = true
client_id = ${_GCP__OAUTH_CLIENT_ID}
client_secret = ${_GCP__OAUTH_CLIENT_SECRET}
scopes = openid email profile
auth_url = https://accounts.google.com/o/oauth2/v2/auth
token_url = https://oauth2.googleapis.com/token
allowed_domains = redhat.com
allow_sign_up = true
allow_assign_grafana_admin = false
; auto_assign_org_role = Editor
auto_login = false                                          # Do not force OAuth login.
skip_org_role_sync = true                                   # Set Role on first login only.
; role_attribute_path = contains(groups[*], 'admin') && 'Admin' || 'Viewer'
cfgEOF
        chmod 00600 "${_SVC__OWN_DATA_DIR}${svcConfDir}/grafana.ini"

        # Create Organization provisioning file.
        : cat - 0<<cfgEOF # 1> "${_SVC__OWN_DATA_DIR}${gfProvDir}/organizations/org.yaml"
apiVersion: 1

organizations:
  - name: Red Hat HP MPEX Integrity Engineering
    org_id: 1
cfgEOF

        # Create Podman Network.
        podman network create "${ctrNet}" 2> /dev/null || true
        # Create Quadlet container file.
        mkdir -p "${quadletUsrDir}"
        cat - 0<<cfgEOF 1> "${quadletUsrDir}/${systemdSvcName}.container"
[Unit]
Description=Grafana Dashboard Service
After=network-online.target

[Container]
Image=docker.io/grafana/grafana:latest
ContainerName=${svcCtrName}
AutoUpdate=registry
Network=${ctrNet}
Environment=GF_PATHS_PROVISIONING=${gfProvDir@Q}
User=500
UserNS=keep-id:uid=500
Volume=${_SVC__OWN_DATA_DIR}${svcConfDir}:${svcConfDir}:ro,Z
Volume=${_SVC__OWN_DATA_DIR}${gfProvDir}:${gfProvDir}:ro,Z
Volume=${_SVC__OWN_DATA_DIR}${svcDataDir}:${svcDataDir}:Z

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
<details><summary>Reset Administrator Password (Emergency Access)</summary>

If you need to regain access to the Administrator Account or reset its
password, use the Grafana CLI:
```shell
( set -euo pipefail; shopt -s inherit_errexit
    typeset svcCtrName=svc--grafana

    # Reset password for the default Administrator Account.
    podman exec -it "${svcCtrName}" \
        grafana-cli admin reset-admin-password '...newPwd...'
true ); echo $?
```
**Use cases:**
  - Locked out of Grafana (forgot all Administrator Account's passwords).
  - Need to re-enable the default Administrator Account.
  - Emergency access without other Administrator Accounts.

**Notes:**
  - This command works even if the Administrator Account is disabled in the UI.
  - The actual default Administrator UserName is `redhat` (configured in
    `grafana.ini`).
  - After reset, login with `redhat:...newPwd...` credential.
</details>
<details><summary>Disable/Enable Administrator Account via CLI</summary>

You can disable or enable the default Administrator Account using the Grafana
REST API:
```shell
( set -euo pipefail; shopt -s inherit_errexit
    typeset crdAdm="${_GF__CRD_ADM-...gfAdm...:...lclAdmPwd...}"
    typeset usrName=redhat
    typeset apiBaseURL='http://localhost:3000/api'
    typeset svcCtrName=svc--grafana
    typeset usrID=

    # Handle credential input.
    [ -z "${crdAdm}" ] && read -p 'Grafana Administrator Username: ' crdAdm
    [[ "${crdAdm}" =~ : ]] || {
        read -sp 'Grafana Administrator Password: ' && echo
        crdAdm+=":${REPLY}"; unset REPLY
    }

    # Get the User ID for the Administrator Account.
    usrID=$(
        podman exec "${svcCtrName}" \
            curl -fsSL\
                -u "${crdAdm}" \
                "${apiBaseURL}/users/lookup?loginOrEmail=${usrName}" |
        jq -r '.id'
    )

    # Disable the Administrator Account.
    podman exec "${svcCtrName}" \
        curl -fsSL \
            -X PUT \
            -u "${crdAdm}" \
            -H "Content-Type: application/json" \
            "${apiBaseURL}/admin/users/${usrID}/disable"

    # Enable the Administrator Account.
    podman exec "${svcCtrName}" \
        curl -fsSL \
            -X PUT \
            -u "${crdAdm}" \
            -H "Content-Type: application/json" \
            "${apiBaseURL}/admin/users/${usrID}/enable"
true ); echo $?
```
**Notes:**
  - Disabling the default Administrator Account is useful after creating other
    Administrator Accounts.
  - Alternatively, use the Web UI (Administration → Users → Disable).
  - Use ONLY local credential, not SSO.
</details>
<details><summary>Install Plugins</summary>

Install PlugIns using `grafana` cli:
```shell
( set -euo pipefail; shopt -s inherit_errexit
    typeset crdAdm="${_GF__CRD_ADM-...gfAdm...:...lclAdmPwd...}"
    typeset apiBaseURL='https://...svcHost.../api'
    typeset svcCtrName=svc--grafana
    typeset systemdSvcName=container--grafana
    typeset e=
    typeset -i wInt=0 wMax=0
    typeset -a pluginIDs=(
        # List of PlugIn IDs to install.
        grafana-opensearch-datasource
    )

    # Handle credential input.
    [ -z "${crdAdm}" ] && read -p 'Grafana Administrator Username: ' crdAdm
    [[ "${crdAdm}" =~ : ]] || {
        read -sp 'Grafana Administrator Password: ' && echo
        crdAdm+=":${REPLY}"; unset REPLY
    }

    typeset enaPlugins="$(
        curl -fsSL \
            -u "${crdAdm}" \
            "${apiBaseURL}/plugins?enabled=true" |
        jq -c '[.[].id]'
    )"

    # Install PlugIns.
    for e in "${pluginIDs[@]}"; do
        if \
            jq -e \
                --arg id "${e}" \
                '. | index($id)' \
                0<<<"${enaPlugins}" \
                &> /dev/null
        then
            echo "PlugIn \`${e}\` is already installed."
        else
            echo "Installing PlugIn \`${e}\`..."
            podman exec "${svcCtrName}" grafana cli plugins install "${e}"
        fi
    done

    # Restart Grafana to load newly installed PlugIns.
    echo 'Restarting Grafana...'
    systemctl --user restart "${systemdSvcName}.service"

    # Monitor Grafana startup.
    (   # Isolate `SECONDS` reset.
        # Grafana startup.
        SECONDS=0 wInt=15 wMax=300      # 5 min. Max.
        while ((SECONDS < wMax)); do
            curl -fsSL \
                -u "${crdAdm}" \
                --max-time "${wInt}" \
                "${apiBaseURL}/health" \
                &> /dev/null && break
            echo "Waited ${SECONDS}/${wMax} sec.: "\
'Starting up Grafana...' 1>&2
        done
        ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'Grafana startup.' 1>&2; exit 2; }
        true
    )

    # List all installed PlugIns.
    {
        echo -e 'ID\tNAME\t(TYPE)'
        curl -fsSL \
            -u "${crdAdm}" \
            "${apiBaseURL}/plugins?enabled=true" |
        jq -r '.[] | [.id, .name, "(\(.type))"] | @tsv' |
        sort -k 1,1 -t $'\t'
    } | column -ts $'\t'
true ); echo $?
```
**Notes:**
  - Most common PlugIns (Elasticsearch, Prometheus, etc.) are pre-installed as
    core PlugIns.
</details>
<details><summary>Create Organizations</summary>

Organizations in Grafana cannot be provisioned via configuration files yet. Use
REST API to create organizations programmatically:
```shell
( set -euo pipefail; shopt -s inherit_errexit
    typeset crdAdm="${_GF__CRD_ADM-...gfAdm...:...lclAdmPwd...}"
    typeset apiBaseURL='https://...svcHost.../api'
    typeset -i i=0
    typeset -a orgNames=(
        # Organization names indexed by `id` (index 0 = id 1).`
        '...orgName_1...'
    )

    # Handle credential input.
    [ -z "${crdAdm}" ] && read -p 'Grafana Administrator Username: ' crdAdm
    [[ "${crdAdm}" =~ : ]] || {
        read -sp 'Grafana Administrator Password: ' && echo
        crdAdm+=":${REPLY}"; unset REPLY
    }

    # Create/update Organizations.
    for i in "${!orgNames[@]}"; do
        if \
            curl -fsSL \
                -u "${crdAdm}" \
                "${apiBaseURL}/orgs/$((i+1))" \
                &> /dev/null
        then
            curl -fsSL \
                -X PUT \
                -u "${crdAdm}" \
                -H "Content-Type: application/json" \
                -d "$(
                    jq -cn --arg oName "${orgNames[${i}]}" '{name: $oName}'
                )" \
                "${apiBaseURL}/orgs/$((i+1))" \
                1> /dev/null
        else
            curl -fsSL \
                -X POST \
                -u "${crdAdm}" \
                -H "Content-Type: application/json" \
                -d "$(
                    jq -cn --arg oName "${orgNames[${i}]}" '{name: $oName}'
                )" \
                "${apiBaseURL}/orgs" \
                1> /dev/null
        fi
    done

    # List all Organizations.
    {
        echo -e 'ID\tNAME'
        curl -fsSL \
            -u "${crdAdm}" \
            "${apiBaseURL}/orgs" |
        jq -r '.[] | [.id, .name] | @tsv' |
        sort -nk 1,1 -t $'\t'
    } | column -ts $'\t'
true ); echo $?
```
**Notes:**
  - Google OAuth via `curl` is not practical (requires browser + SSO chain).
  - Use local Administrator Account for CLI/scripted operations.
  - Organization IDs are auto-assigned sequentially (1, 2, 3, ...).
  - The first Organization (ID 1) is created automatically on Grafana startup.
</details>
<details><summary>Compacting DataBase</summary>

Over time, Grafana's SQLite DataBase can accumulate unused space from deleted
Records (Dashboards, Folders, etc.). Use the `VACUUM` command to reclaim this
space:
```shell
( set -euo pipefail; shopt -s inherit_errexit
    typeset systemdSvcName=container--grafana
    typeset svcOwnDataDir=/opt/web-app/grafana
    typeset svcDataDir=/var/lib/grafana
    typeset dbPath="${svcOwnDataDir}${svcDataDir}/grafana.db"
    typeset bkPath="${svcOwnDataDir}${svcDataDir}/backups/grafana.db.$(
        date -u +%Y%m%d-%H%M%S
    ).bak"
    typeset e= oTbl= nTbl=

    export _GF__DB__RST="${_GF__DB__RST:-}"
    export _GF__DB__BAK_KEEP="${_GF__DB__BAK_KEEP:-5}"

    # Stop Grafana service.
    systemctl --user stop "${systemdSvcName}.service"

    # Create BackUp with timestamp.
    mkdir -p "${bkPath%/*}"
    # Atomic BackUp using VACUUM INTO (SQLite 3.27.0+).
    sqlite3 "${dbPath}" "VACUUM INTO '${bkPath}';" ||
        cp -pf "${dbPath}" "${bkPath}"

    # Verify BackUp was created.
    [ -f "${bkPath}" ]
    echo "Created BackUp: ${bkPath}"

    # Clean up old BackUps (keep the last N).
    ((_GF__DB__BAK_KEEP > 0)) && {
        ls -t "${bkPath%.*.*}".*.bak 2>/dev/null |
        tail -n +$((_GF__DB__BAK_KEEP + 1)) |
        xargs -r rm -f
    }

    # Reset Table Sequence Numbers if requested.
    ((_GF__DB__RST)) && {
        oTbl="$(sqlite3 "${dbPath}" "
            SELECT name,seq FROM sqlite_sequence ORDER BY name;
        ")"
        while IFS= read -r e; do
            sqlite3 "${dbPath}" "
                UPDATE sqlite_sequence
                SET seq = (
                    SELECT COALESCE(MAX(id), 0) FROM \"${e}\"
                )
                WHERE name = '${e}';
            "
        done 0< <(sqlite3 "${dbPath}" "SELECT name FROM sqlite_sequence;")
        nTbl="$(sqlite3 "${dbPath}" "
            SELECT name,seq FROM sqlite_sequence ORDER BY name;
        ")"

        # Display Table Sequence Number changes.
        {
            echo 'TABLE|OLD_SEQ|NEW_SEQ'
            join -t '|' -1 1 -2 1 -o 1.1,1.2,2.2 \
                <(echo "${oTbl}") \
                <(echo "${nTbl}")
        } | column -ts '|'
    }

    # Compact database to reclaim space from deleted Records.
    #   Database is on Host FS, mounted into Container as volume.
    sqlite3 "${dbPath}" "VACUUM;"

    # Restart Grafana service.
    systemctl --user start "${systemdSvcName}.service"
true ); echo $?
```
**Notes:**
  - DataBase compaction is only needed if disk space is a concern. Grafana
    handles fragmentation well in normal operations.
  - **BackUp:** Automatic BackUp is created before any modifications with
    timestamp format: `grafana.db.YYYYMMDD-HHMMSS.bak`
  - **BackUp location:** `/opt/web-app/grafana/var/lib/grafana/backups/`
  - **BackUp retention:** Set `_GF__DB__BAK_KEEP=N` to keep last N BackUps
    (default: 5). Set to 0 to disable cleanup.
  - **Sequence reset:** Set `_GF__DB__RST=1` to reset auto-increment sequences
    to match actual max IDs.
</details>


## Operational Tasks
<details><summary>Connect Data Sources</summary>
<details><summary>Data Source Definitions (Chaos)</summary>

```shell
{
    export _GF__DS__GIT_URL="${_GF__DS__GIT_URL:-}"
    export _GF__DS__GIT_BR="${_GF__DS__GIT_BR:-}"
    export _GF__DS__GIT_WT="${_GF__DS__GIT_WT:-}"
    export _GF__DS__CFG="$(eval "$(
            cat - 0<<'scrEOF'
        export _BW__NOTE_NAME='note.Grafana--Chaos&G11N'
        export _BW__NOTE_SUB_FLD='datasource.hp--mpex--ieng'
        export BW_SESSION="${BW_SESSION:+$([ -f "${BW_SESSION}" ] && cat "${BW_SESSION}" || echo "${BW_SESSION}")}"
        export BW_SESSION="$((bw status | grep -q '"status":"unlocked"') && echo "${BW_SESSION}" || bw unlock --raw || bw login --raw)"
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
                        .fields[]? | select(.name == $fn__c).value |
                        fromjson | .shellEnv
                    ' \
                0<<<"${bwData}"
            )"
            eval "${__shOpt}"; unset __shOpt
        } 1>&2
        typeset gitURL="${_GF__DS__GIT_URL:-git@github.com:krkn-chaos/visualize.git}"
        typeset gitBr="${_GF__DS__GIT_BR:-main}"
        typeset gitWT="${_GF__DS__GIT_WT:-}"
        typeset wsDir=
        { [ -n "${gitWT}" ] && [ -d "${gitWT}/" ]; } || {
            wsDir="$(mktemp -d /tmp/gf--ds-import.XXXXXX)"
            trap "rm -rf ${wsDir@Q}/" EXIT
            gitWT="${wsDir}/visualize"
            (
                cd "${wsDir}"
                git clone \
                    --depth 1 --single-branch --no-tags \
                    --branch "${gitBr}" "${gitURL}" \
                    "${gitWT}/"
            )
        }
        {
            cat - 0<<'cfgEOF'
shellVars:
  orgID: 1
provCfg:
---
cfgEOF
            yq eval '
                select(
                    (.kind == "ConfigMap") and
                    (.data."ocp-prometheus.yml" != null)
                ) |
                .data."ocp-prometheus.yml"
            ' "${gitWT}/krkn-visualize/templates/krkn-visualize.yaml.template" |
            eval "$(cat 0<<subEOF
eval "envsubst '" \\\$\\{{$(IFS=, eval 'echo "${!ES_*}"')}\\} "'"
subEOF
            )"
        } | yq -o json eval-all '
            select(di == 1).datasources|=map(
                select(.type != "prometheus") |
                .jsonData.flavor="opensearch" |
                .database|=sub("\*"; "") |
                .jsonData.database|=sub("\*"; "")
            ) |
            select(di == 1) as $provCfg |
            select (di == 0) |
            .provCfg=$provCfg
        ' | jq -c .
scrEOF
    )")"
}
```
</details>

```shell
# Run the script defining the Data Sources FIRST!!!
( set -euo pipefail; shopt -s inherit_errexit
    typeset crdAdm="${_GF__CRD_ADM-...gfAdm...:...lclAdmPwd...}"
    typeset apiBaseURL='https://...svcHost.../api'
    typeset e= dsUID= dsName= dsAPIidPath=
    typeset -i orgID=0 dsID=0

    typeset dsCfg="$(
        jq -c \
            '
                .shellVars.orgID as $orgID |
                .provCfg.datasources|=map(
                    .orgId = $orgID |
                    .version = 1
                )
            ' \
            0<<<"${_GF__DS__CFG:-"$(
        cat - 0<<'cfgEOF' | yq -o json e . | jq -c .
# This is just an EXAMPLE!!! NOT actual Data Source definitions.
shellVars:
  orgID: 0
provCfg:    # Define Data Sources in provisioning YAML format.
  apiVersion: 1
  datasources:
  - name: <dsName>
    type: <dsType>
    access: <{proxy|direct}>
    orgId: 0
    uid: '[<rgx:^[_0-9A-Za-z-]{1,40}$>]'    # Optional, for reliable match.
    url: <dsURL>
    basicAuth: true
    basicAuthUser: <dsCrdUsr>
    jsonData:
      esVersion: 80
      timeField: timestamp
      logMessageField: message
      logLevelField: level
      index: krkn-telemetry*
    secureJsonData:
      basicAuthPassword: <dsCrdPwd>
    version: 1
    editable: <{true|false}>
cfgEOF
            )"}"
    )"

    # Handle credential input.
    [ -z "${crdAdm}" ] && read -p 'Grafana Administrator Username: ' crdAdm
    [[ "${crdAdm}" =~ : ]] || {
        read -sp 'Grafana Administrator Password: ' && echo
        crdAdm+=":${REPLY}"; unset REPLY
    }

    # Assign appropriate pre-defined variables from `${dsCfg}`.
    while IFS= read -r e; do
        [[ -v "${e}" ]] && eval "$(
            printf '%s=%q' "${e}" "$(jq -r ".shellVars.${e}" 0<<<"${dsCfg}")"
        )"
    done 0< <(jq -r '.shellVars | keys[]' 0<<<"${dsCfg}")

    # Create/update each Data Source.
    while IFS= read -r e; do
        dsUID="$(jq -r '(.uid // empty)' 0<<<"${e}")"
        dsName="$(jq -r '.name' 0<<<"${e}")"
        [ -n "${dsUID}" ] &&
            dsAPIidPath="uid/${dsUID}" ||
            dsAPIidPath="name/$(
                python3 \
                    -c "
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''), end='')
                    " \
                    "${dsName}"
            )"
        dsID="$(
            curl -fsSL \
                -u "${crdAdm}" \
                -H "X-Grafana-Org-Id: ${orgID}" \
                "${apiBaseURL}/datasources/${dsAPIidPath}" |
            jq -r '.id'
        )" || dsID=0
        if ((dsID)); then
            curl -fsSL \
                -X PUT \
                -u "${crdAdm}" \
                -H "Content-Type: application/json" \
                -H "X-Grafana-Org-Id: ${orgID}" \
                -d "$(jq -c 'del(.version)' 0<<<"${e}")" \
                "${apiBaseURL}/datasources/${dsID}" \
                1> /dev/null
        else
            curl -fsSL \
                -X POST \
                -u "${crdAdm}" \
                -H "Content-Type: application/json" \
                -H "X-Grafana-Org-Id: ${orgID}" \
                -d "${e}" \
                "${apiBaseURL}/datasources" \
                1> /dev/null
        fi
    done 0< <(jq -c '.provCfg.datasources[]' 0<<<"${dsCfg}")

    # List all Data Sources in Organization with health status.
    {
        echo -e 'ID\tNAME\t(TYPE)\t[STATUS]'
        join -t $'\t' -1 1 -2 1 -o 1.1,1.2,1.3,2.2 \
            <(
                curl -fsSL \
                    -u "${crdAdm}" \
                    -H "X-Grafana-Org-Id: ${orgID}" \
                    "${apiBaseURL}/datasources" |
                jq -r '.[] | [.id, .name, "(\(.type))"] | @tsv' |
                sort -nk 1,1 -t $'\t'
            ) <(
                curl -fsSL \
                    -u "${crdAdm}" \
                    -H "X-Grafana-Org-Id: ${orgID}" \
                    "${apiBaseURL}/datasources" |
                jq -r '.[].id' |
                while IFS= read -r e; do
                    {
                        curl -fsSL \
                            -u "${crdAdm}" \
                            -H "X-Grafana-Org-Id: ${orgID}" \
                            "${apiBaseURL}/datasources/${e}/health" |
                        jq -r --arg id "${e}" \
                            '[$id, "[\((.status // "N/A"))]"] | @tsv'
                    } || echo "${e}"$'\tERROR'
                done |
                sort -nk 1,1 -t $'\t'
            )
    } | column -ts $'\t'
true ); echo $?
```
**Notes:**
  - Use local Administrator Account for CLI/scripted operations.
  - Use `X-Grafana-Org-Id` header to specify Organization context.
</details>
<details><summary>Import Dashboards</summary>
<details><summary>Dashboard Definitions (Chaos)</summary>

```shell
{
    export _GF__DB__GIT_WT="${_GF__DB__GIT_WT:-}"
    export _GF__DB__GIT_BR="${_GF__DB__GIT_BR:-}"
    export _GF__DB__CFG="$(cat - 0<<'cfgEOF' | yq -o json e . | jq -c .
shellVars:
  orgID: 1
dbCfg:
  - dbPath:
      name: /Chaos/Generic
    dbGetter: |
      typeset gitURL="${_GF__DB__GIT_URL:-git@github.com:krkn-chaos/visualize.git}"
      typeset gitBr="${_GF__DB__GIT_BR:-main}"
      typeset gitWT="${_GF__DB__GIT_WT:-}"
      typeset wsDir=
      { [ -n "${gitWT}" ] && [ -d "${gitWT}/" ]; } || {
        wsDir="$(mktemp -d /tmp/gf--db-import.XXXXXX)"
        trap "rm -rf ${wsDir@Q}/" EXIT
        gitWT="${wsDir}/visualize"
        (
          cd "${wsDir}"
          git clone \
            --depth 1 --single-branch --no-tags \
            --branch "${gitBr}" \
            "${gitURL}" "${gitWT}/"
          make -C "${gitWT}/"
        )
      }
      find "${gitWT}/rendered/" -type f -name '*.json' -exec cat '{}' \; |
        jq -s . 1>&3
cfgEOF
    )"
}
```
</details>

```shell
# Run the script defining the Dashboards FIRST!!!
( set -euo pipefail; shopt -s inherit_errexit
    typeset crdAdm="${_GF__CRD_ADM-...gfAdm...:...lclAdmPwd...}"
    typeset apiBaseURL='https://...svcHost.../api'
    typeset e= seg= pSeg= dbPathUID= dbPathName= folderUID= parentUID=
    typeset dbJSON= dbTitle= dbUID=
    typeset -i orgID=0

    typeset dbCfg="${_GF__DB__CFG:-"$(
        cat - 0<<'cfgEOF' | yq -o json e . | jq -c .
# This is just an EXAMPLE!!! NOT actual Dashboard definitions.
shellVars:
  orgID: 0
dbCfg:
  - dbPath:
      # Each Path Segment MUST be URL Endoded. Ignored if the UID-based
      #   macthing succeeded.
      name: /topFolder/subFolder
      # Optional, for faster search (`^[_0-9A-Za-z-]{1,40}$`) and take
      #   precedence.
      uid: topFolder--subFolder
    dbGetter: | # MUST yield array of Grafana Dashboard JSON format to FD 3!!!
      {
        curl -fsSL 'https://host.dom/path/db.json'
        cat '/path/to/file.json'
      } | jq -s . 1>&3
cfgEOF
    )"}"

    # Handle credential input.
    [ -z "${crdAdm}" ] && read -p 'Grafana Administrator Username: ' crdAdm
    [[ "${crdAdm}" =~ : ]] || {
        read -sp 'Grafana Administrator Password: ' && echo
        crdAdm+=":${REPLY}"; unset REPLY
    }

    # Assign appropriate pre-defined variables from `${dbCfg}`.
    while IFS= read -r e; do
        [[ -v "${e}" ]] && eval "$(
            printf '%s=%q' "${e}" "$(jq -r ".shellVars.${e}" 0<<<"${dbCfg}")"
        )"
    done 0< <(jq -r '.shellVars | keys[]' 0<<<"${dbCfg}")

    # Create or update Dashboards.
    while IFS= read -r e; do
        dbPathUID="$(jq -r '(.dbPath.uid // empty)' 0<<<"${e}")"
        dbPathName="$(jq -r '(.dbPath.name // empty)' 0<<<"${e}")"
        # Find or create Folder hierarchy.
        if {
            [ -z "${dbPathUID}" ] || ! pSeg="$(
                curl -fsSL \
                    -u "${crdAdm}" \
                    "${apiBaseURL}/folders/${dbPathUID}" |
                jq -r '"/" + ([.parents[]?.title, .title] | join("/"))'
            )"
        }; then
            # Fallback to peruse Folder hierarchy by name.
            dbPathUID= parentUID= pSeg=
            while read -d / -r seg; do
                [ -z "${seg}" ] &&
                    continue ||
                    seg="$(
                        python3 \
                            -c "
import sys, urllib.parse
print(urllib.parse.unquote(sys.argv[1]), end='')
                            " \
                            "${seg}"
                    )"
                pSeg+="/${seg}"

                # Search for Folder by name under parent.
                folderUID="$(
                    curl -fsSL \
                        -u "${crdAdm}" \
                        "${apiBaseURL}/folders${parentUID:+?parentUid=${parentUID}}" |
                    jq -r \
                        --arg title "${seg}" \
                        --arg parent "${parentUID}" \
                        '
                            .[] | select(
                                (.title == $title) and
                                ((.parentUid // "") == $parent)
                            ).uid
                        '
                )"

                # Using REST API, it possible to create multiple Folders with
                #   the same name under the same parent. Exit out and tell user
                #   to delete the duplicated Folders via Web UI.
                (("$(echo -n "${folderUID}" | wc -l)")) && {
                    cat - 0<<errEOF 1>&2
ERROR:
    Found multiple Folders with name: ${pSeg}
    Please delete duplicates via Web UI.
errEOF
                    false
                }

                if [ -n "${folderUID}" ]; then
                    parentUID="${folderUID}"
                else
                    # Create Folder.
                    parentUID="$(
                        curl -fsSL \
                            -X POST \
                            -u "${crdAdm}" \
                            -H "Content-Type: application/json" \
                            -d "$(
                                jq -cn \
                                    --arg title "${seg}" \
                                    --arg parent "${parentUID}" \
                                    '
                                        {title: $title} |
                                        if ($parent != "") then
                                            .parentUid=$parent
                                        end
                                    '
                            )" \
                            "${apiBaseURL}/folders" |
                        jq -r '.uid'
                    )"
                fi
            done 0<<<"${dbPathName}/"
            dbPathUID="${parentUID}"
        fi

        # Import Dashboards to Folder.
        while IFS= read -r dbJSON; do
            [ -n "${e}" ] && {
                echo "Importing Dashboards to: ${pSeg}/"
                e=
            }
            dbTitle="$(jq -r '.title' 0<<<"${dbJSON}")"
            echo " |- ${dbTitle}"

            [ -z "$(jq -r '(.uid // empty)' 0<<<"${dbJSON}")" ] && {
                # Query for existing dashboard by Title in Folder to get UID.
                dbUID="$(
                    curl -fsSL \
                        -u "${crdAdm}" \
                        -H "X-Grafana-Org-Id: ${orgID}" \
                        "${apiBaseURL}/search?"\
"type=dash-db&folderUids=${dbPathUID}&query=$(
    python3 \
        -c "
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''), end='')
        " \
        "${dbTitle}"
)"                      |
                    jq -r \
                        --arg title "${dbTitle}" \
                        '.[] | select(.title == $title).uid'
                )"

                # It possible to create multiple Dashboards with the same name
                #   under the same Folder. Exit out and tell user to delete the
                #   duplicated Dashboards via Web UI.
                (("$(echo -n "${dbUID}" | wc -l)")) && {
                    cat - 0<<errEOF 1>&2
ERROR:
    Found multiple Dashboards with name: ${dbTitle}
    Please delete duplicates via Web UI.
errEOF
                    false
                }

                # Inject existing UID if found for idempotent update.
                [ -n "${dbUID}" ] && dbJSON="$(
                    jq -c --arg uid "${dbUID}" '.uid=$uid' 0<<<"${dbJSON}"
                )"
            }

            curl -fsSL \
                -X POST \
                -u "${crdAdm}" \
                -H "Content-Type: application/json" \
                -H "X-Grafana-Org-Id: ${orgID}" \
                -d "$(
                    jq -cn \
                        --argjson db "${dbJSON}" \
                        --arg fUID "${dbPathUID}" \
                        '{
                            dashboard: $db,
                            folderUid: $fUID,
                            overwrite: true
                        }' ||
                    echo '{}'
                )" \
                "${apiBaseURL}/dashboards/db" \
                1> /dev/null
        done 0< <(
            eval "$(cat - 0<<scrEOF
exec 3>&1; ( set -euxo pipefail; shopt -s inherit_errexit
$(jq -r '.dbGetter' 0<<<"${e}")
true ) 1>&2; exec 3>&-
scrEOF
            )" | jq -cr '.[]'
        )
    done 0< <(jq -c '.dbCfg[]' 0<<<"${dbCfg}")

    # List all Dashboards in Organization.
    {
        echo -e 'ID\tTITLE\t(UID)'
        curl -fsSL \
            -u "${crdAdm}" \
            -H "X-Grafana-Org-Id: ${orgID}" \
            "${apiBaseURL}/search?type=dash-db" |
        jq -r '.[] | [.id, .title, "(\(.uid))"] | @tsv' |
        sort -nk 1,1 -t $'\t'
    } | column -ts $'\t'
true ); echo $?
```
**Notes:**
  - Use local Administrator Account for CLI/scripted operations.
  - Use `X-Grafana-Org-Id` header to specify Organization context.
  - Export from Grafana.com: `curl https://grafana.com/api/dashboards/{id}/revisions/{revision}/download`
</details>

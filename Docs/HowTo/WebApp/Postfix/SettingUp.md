# Setting Up Postfix (Containerized)
##  Installation.
<details><summary>Preparing Host</summary>

```shell
__SHELL=0 __DBG=0 \
    _SVC__OWN_DATA_DIR=/opt/web-app/postfix \
    _SVC__FQDN='...svcFQDN...' \
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
                bw get notes "${_BW__NOTE_NAME}" || {
                    echo "You may NOT have access to BitWarden Note \`${_BW__NOTE_NAME}\`." 1>&2
                    echo false
                }
            )"
            eval "${__shOpt}"; unset __shOpt
        }
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset ownUsr="$(id -un)"
        typeset ownGrp=web-app
        typeset ctrNet=net--web-app
        typeset ctrCIDR=
        typeset svcCtrName=svc--postfix
        typeset quadletUsrDir="${HOME}/.config/containers/systemd"
        typeset systemdSvcName=container--postfix

        ((__DBG)) && {
            podman container run \
                --name "${svcCtrName}" \
                --rm -it \
                --network "${ctrNet}" \
                -e HOSTNAME="${_SVC__FQDN}" \
                -e ALLOWED_SENDER_DOMAINS="${_SVC__FQDN#*.}" \
                -e ALLOW_EMPTY_SENDER_DOMAINS=false \
                -e POSTFIX_mynetworks="127.0.0.0/8 $(
                    podman network inspect "${ctrNet}" \
                        --format '{{range .Subnets}}{{.Subnet}}{{end}}'
                )" \
                -e RELAYHOST="${_SVC__SMTP_RLY__HST}" \
                -e RELAYHOST_USERNAME="${_SVC__SMTP_RLY__USR}" \
                -e RELAYHOST_PASSWORD="${_SVC__SMTP_RLY__PWD}" \
                docker.io/boky/postfix:latest
            exit 0
        }

        sudo bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<sudoEOF
            # Prepare Directories.
            mkdir -p ${_SVC__OWN_DATA_DIR@Q}
            chown -R ${ownUsr@Q}:${ownGrp@Q} ${_SVC__OWN_DATA_DIR@Q}/
            chmod -R 02775 ${_SVC__OWN_DATA_DIR@Q}/
            setfacl \
                -Rm u:${ownUsr@Q}:rwx,g::rwx,m::rwx,d:u:${ownUsr@Q}:rwx,d:g::rwx,d:m::rwx \
                ${_SVC__OWN_DATA_DIR@Q}/

            true
sudoEOF
        )"

        # Create Podman Network.
        podman network create "${ctrNet}" 2> /dev/null || true
        # Get network subnet CIDR for `${POSTFIX_mynetworks}`.
        ctrCIDR="$(
            podman network inspect "${ctrNet}" \
                --format '{{range .Subnets}}{{.Subnet}}{{end}}'
        )"; [ -n "${ctrCIDR}" ]
        # Create Quadlet container file.
        mkdir -p "${quadletUsrDir}"
        cat - 0<<cfgEOF 1> "${quadletUsrDir}/${systemdSvcName}.container"
[Unit]
Description=Postfix SMTP Relay
After=network-online.target

[Container]
Image=docker.io/boky/postfix:latest
ContainerName=${svcCtrName}
AutoUpdate=registry
Network=${ctrNet}
Environment=HOSTNAME=${_SVC__FQDN@Q}
Environment=ALLOWED_SENDER_DOMAINS=$(
    typeset svcFQDN="${_SVC__FQDN#*.}"
    echo "${svcFQDN@Q}"
)
# Enforce domain validation for sender addresses.
Environment=ALLOW_EMPTY_SENDER_DOMAINS=false
# Allow relaying to any recipient domain (open relay for internal network).
Environment=POSTFIX_mynetworks=$(
    typeset pfNet="127.0.0.0/8 ${ctrCIDR}"
    echo "${pfNet@Q}"
)
# SMTP Upstream Relay.
Environment=RELAYHOST=${_SVC__SMTP_RLY__HST@Q}
Environment=RELAYHOST_USERNAME=${_SVC__SMTP_RLY__USR@Q}
Environment=RELAYHOST_PASSWORD=${_SVC__SMTP_RLY__PWD@Q}

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

        true
cmdEOF
    )"; echo $?
```
</details>


## Notes
  - The Postfix container uses the `boky/postfix` image, which is a lightweight
    SMTP Relay.
  - **SMTP Upstream Relay Required**: Cloud providers (AWS, GCP, Azure) block
    outbound port 25. Postfix relays through an upstream SMTP Server.
      - **AWS SES Setup**: See `../../Cloud/AWS/SES.md` for domain verification
        and SMTP Credentials creation. For verified domains, the DKIM will be
        provided automatically.
  - No authentication required for local network communication
    (Service → Postfix).
  - Service Container connects via the Podman Network using container name DNS
    (`smtp://svc--postfix:25`).
  - Emails may be flagged as spam by recipients without proper SPF/DKIM
    configuration (the SMTP Uptream Relay may provides it).
  - This setup is suitable for internal notifications and invites, not
    production mass mailing.

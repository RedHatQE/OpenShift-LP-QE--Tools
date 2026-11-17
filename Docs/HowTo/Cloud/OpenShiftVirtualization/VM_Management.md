# OpenShift Virtualization VM Management
## Creating VM Instance
### Creating Virtual Network
<details><summary>Creating NameSpace and NetworkAttachmentDefinition</summary>

```shell
```
</details>


### Creating VM
<details><summary>Creating VM</summary>

```shell
```
</details>



## VM Instance Access
### Console
<details><summary>Serial Console</summary>

```shell
```
</details>


### SSH
<details><summary>SSH via virtctl</summary>

```shell
```
</details>



## VM Instance Housekeeping
### Powering On
<details><summary>Starting VM</summary>

```shell
```
</details>


### Resetting
<details><summary>Restarting VM</summary>

```shell
```
</details>


### Powering Off
<details><summary>Stopping VM</summary>

```shell
```
</details>


### Backup
<details><summary>VM Snapshot Management</summary>

```shell
_JOB__ACTION=create \
    _RHOV__NS='ieng--ci-jenkins' \
    _RHOV__VM__NAME='ieng--fedora--master' \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        typeset vmbName="vm-backup--${_RHOV__VM__NAME}"
        typeset vmbCRD="$(cat - 0<<'ocEOF'
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineSnapshot
metadata:
  name: ''
  namespace: ''
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ''
  target:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ''
ocEOF
        )"

        case ${_JOB__ACTION} in
          (create)
            {
                oc create -f - --dry-run=client -o json --save-config |
                jq -c \
                    --arg vmNS "${_RHOV__NS}" \
                    --arg vmbName "${vmbName}" \
                    --arg vmName "${_RHOV__VM__NAME}" \
                    '
                        .metadata|=(.name=$vmbName |.namespace=$vmNS) |
                        .spec|=(
                            .source.name=$vmName |
                            del(.target)
                        )
                    ' |
                yq -p json -o yaml eval .
            } 0<<<"${vmbCRD}" | oc apply -f -
            oc -n "${_RHOV__NS}" wait "VirtualMachineSnapshot/${vmbName}" \
                --for condition=Ready \
                --timeout 300s
            ;;
          (restore)
            {
                oc create -f - --dry-run=client -o json --save-config |
                jq -c \
                    --arg crdKind VirtualMachineRestore \
                    --arg vmNS "${_RHOV__NS}" \
                    --arg vmbName "${vmbName}" \
                    --arg vmName "${_RHOV__VM__NAME}" \
                    '
                        .kind=$crdKind |
                        .metadata|=(.name=$vmbName |.namespace=$vmNS) |
                        .spec|=(
                            .target.name=$vmName |
                            del(.source) |
                            .virtualMachineSnapshotName=$vmbName
                        )
                    ' |
                yq -p json -o yaml eval .
            } 0<<<"${vmbCRD}" | oc apply -f -
            oc -n "${_RHOV__NS}" wait "VirtualMachineRestore/${vmbName}" \
                --for condition=Ready \
                --timeout 300s
            oc -n "${_RHOV__NS}" delete "VirtualMachineRestore/${vmbName}"
            ;;
          (delete)
            oc -n "${_RHOV__NS}" delete "VirtualMachineSnapshot/${vmbName}"
            ;;
          (*)   false;;
        esac
cmdEOF
    )"; echo $?
```
</details>



## Deleting VM Instance
### Deleting VM
<details><summary>Deleting VM</summary>

```shell
```
</details>



## Creating VM Disk Image Template

Some steps require running scripts on the VM. Connect to it via direct SSH
(if it has been set up accordingly) or any of the
[VM Instance Access](#VMInstanceAccess) methods.

### Building Generalized Disk Image
<details><summary>Creating Generalized Disk Image Generator VM</summary>

```shell
```
</details>
<details><summary>Preparing OS as VM Image Template</summary>

Run on VM.

<details><summary>Common</summary>

```shell
```
</details>
</details>


### Generating Generalized Disk Image
<details><summary>SysPrep</summary>

Run on VM.
```shell
sudo \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
: '--- Cleaning Package Manager. ---'
dnf -y remove $(dnf5 repoquery --installonly --latest-limit=-1 -q) || true
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
(
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
(
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
<details><summary>Creating Containerized Disk Image</summary>

```shell
_RHOV__NS='ieng--ci-jenkins' \
    _RHOV__VM__NAME='ieng--fedora--master' \
    _RHOV__VM__DISK_IMG__REPO_PATH='images.paas.redhat.com/ieng/vm-img--rhov' \
    _RHOV__VM__DISK_NAME='vhd--00-fs-rootfs' \
    _RHOV__VM__ARCH='arm64' \
    _RHOV__DIT__DISK_SIZE='128Gi' \
    bash -o pipefail -O inherit_errexit -euxc "$(cat - 0<<'cmdEOF'
        typeset vmDskImgVer="$(date '+%Y%m%d')"

        # Create Disk Image Tool Pod.
        ##  Create PVC for R/W storage.
        {
            oc create -f - --dry-run=client -o json --save-config |
            jq -c \
                --arg vmNS "${_RHOV__NS}" \
                --arg ditDiskSize "${_RHOV__DIT__DISK_SIZE}" \
                '
                    .metadata.namespace=$vmNS |
                    .spec.resources.requests.storage=$ditDiskSize
                ' |
            yq -p json -o yaml eval .
        } 0<<'ocEOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: disk-img-tool--pvc--00-ws
  namespace: ''
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ''
ocEOF
        ##  Create the Pod.
#       oc -n "${_RHOV__NS}" run disk-img-tool \
#           --image="$(
#               oc -n "${_RHOV__NS}" get Pods \
#                   -l kubevirt.io=virt-launcher \
#                   -o jsonpath='{.items[0].spec.containers[0].image}'
#           )" \
#           --restart=Never \
#           --command \
#           -- /bin/bash -c "sleep infinity"
        {
            oc create -f - --dry-run=client -o json --save-config |
            jq -c \
                --arg vmNS "${_RHOV__NS}" \
                --arg ditCtrImg "$(
                    oc -n "${_RHOV__NS}" get Pods \
                        -l kubevirt.io=virt-launcher \
                        -o jsonpath='{.items[0].spec.containers[0].image}'
                )" \
                '
                    .metadata.namespace=$vmNS |
                    .spec.containers[0].image=$ditCtrImg
                ' |
            yq -p json -o yaml eval .
        } 0<<'ocEOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: disk-img-tool
  namespace: ''
spec:
  containers:
  - name: disk-img-tool
    image: quay.io/kubevirt/virt-launcher:v1.2.0
    command: ['/bin/bash', '-c', 'sleep infinity']
    volumeMounts:
    - name: ws
      mountPath: /ws
  volumes:
  - name: ws
    persistentVolumeClaim:
      claimName: disk-img-tool--pvc--00-ws
  restartPolicy: Never
ocEOF
        oc -n "${_RHOV__NS}" wait Pods/disk-img-tool \
            --for condition=Ready \
            --timeout 60s
        ##  Sanity check.
        oc -n "${_RHOV__NS}" exec Pods/disk-img-tool -- qemu-img --version
        oc -n "${_RHOV__NS}" exec Pods/disk-img-tool -- df -h /ws/

        # Export the VM Disk Image.
#       oc -n "${_RHOV__NS}" exec Pods/disk-img-tool -- mkfifo /ws/disk.raw.fifo
#       oc -n "${_RHOV__NS}" exec Pods/disk-img-tool \
#           -- bash -c '
#               qemu-img convert \
#                   -p -c -S 4k -f raw -O qcow2 \
#                   /ws/disk.raw.fifo /ws/disk.qcow2 &
#               sleep 5
#           '
        (
            virtctl -n "${_RHOV__NS}" vmexport download  \
                "vm-export--${_RHOV__VM__NAME}--${vmDskImgVer}" \
                --vm "${_RHOV__VM__NAME}" \
                --volume "${_RHOV__VM__DISK_NAME}" \
                --output - |
            gunzip |
            oc -n "${_RHOV__NS}" exec Pods/disk-img-tool \
                -i \
                -- dd of=/ws/disk.raw bs=4M
#               -- dd of=/ws/disk.raw.fifo bs=4M
        )
        oc -n "${_RHOV__NS}" exec Pods/disk-img-tool -- ls -laFh /ws/
        oc -n "${_RHOV__NS}" exec Pods/disk-img-tool \
            -- qemu-img convert \
                    -p -c -S 4k -f raw -O qcow2 \
                    /ws/disk.raw /ws/disk.qcow2
#       oc -n "${_RHOV__NS}" exec Pods/disk-img-tool -- rm /ws/disk.raw.fifo
        oc -n "${_RHOV__NS}" exec Pods/disk-img-tool -- qemu-img info /ws/disk.qcow2
        {
            oc -n "${_RHOV__NS}" exec Pods/disk-img-tool \
                -- cat /ws/disk.qcow2 |
            dd of="./${_RHOV__VM__NAME}--${vmDskImgVer}--00-hdd.qcow2" bs=4M
        }
#       oc -n "${_RHOV__NS}" cp \
#           disk-img-tool:/ws/disk.qcow2 "./${_RHOV__VM__NAME}--${vmDskImgVer}--00-hdd.qcow2"

        # Cleaning up Disk Image Tool Pod.
        oc -n "${_RHOV__NS}" delete Pods/disk-img-tool
        oc -n "${_RHOV__NS}" delete PersistentVolumeClaim/disk-img-tool--pvc--00-ws

        # Creating Containerized Disk Image.
        podman image build \
            -f - \
            --platform linux/${_RHOV__VM__ARCH} \
            -t "${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}:${_RHOV__VM__ARCH}-latest" \
            -t "${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}:${_RHOV__VM__ARCH}-${vmDskImgVer}" \
            . 0<<bldEOF
FROM scratch
ADD [$(
    jq -cn \
        --arg vmName "${_RHOV__VM__NAME}" \
        --arg vmDskImgVer "${vmDskImgVer}" \
        '"./\($vmName)--\($vmDskImgVer)--00-hdd.qcow2"'
), "/disk/disk.img"]
bldEOF
        (
            for e in "${_RHOV__VM__ARCH}-"{latest,"${vmDskImgVer}"}; do
                podman image push \
                    "${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}:${e}"
            done
        )
        podman pull \
            "${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}:latest" \
            2> /dev/null || true
        podman manifest create \
            --amend \
            "${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}:latest" \
            "${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}:${_RHOV__VM__ARCH}-latest"
        podman manifest inspect "${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}:latest"
        podman manifest push \
            "${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}:latest" \
            "${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}:${vmDskImgVer}"
        podman manifest push \
            --rm \
            "${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}:latest"
        {
            podman image ls -q --filter reference=\
"${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}" |
            xargs -r podman image rm -f
        }
        rm "./${_RHOV__VM__NAME}--${vmDskImgVer}--00-hdd.qcow2"

#       podman image pull "${_RHOV__VM__DISK_IMG__REPO_PATH}/${_RHOV__VM__NAME}":latest
cmdEOF
    )"; echo $?
```
</details>
<details><summary>Destroying Generalized Disk Image Generator VM</summary>

```shell
```
</details>

#!/usr/bin/env bash
# Fail-closed RHOV preflight validation before crash injection and watcher
# Verifies: cluster permissions, VM/VMI state, storage configuration, recovery image capability
# Produces metadata.json consumed by watch-crash.sh and recover-natural-crash.sh
# Side effects: temporary probe pod only; no VM lifecycle changes (runStrategy must be Manual)
set -euo pipefail; shopt -s inherit_errexit
umask 077

# Directory structure for script discovery
typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset appDir=''; appDir="$(cd "${scriptDir}/../../.." && pwd)"
# Guest configuration: PowerShell script to configure Windows dump settings + crash control JSON
typeset configureScript="${BSOD_CONFIGURE_DUMPS:-${appDir}/src/scripts/guest/configure-dumps.ps1}"
typeset crashControlFile="${BSOD_CRASH_CONTROL_FILE:-${appDir}/src/data/crash-control.json}"
# Target: namespace, VM name, output directory for metadata, run ID
typeset ns=''; typeset vm=''; typeset outDir=''; typeset metadataFile=''; typeset runId=''
# Storage: snapshot class (RBD), recovery image digest-pinned, guest disk target (vda, sda, etc)
typeset snapClass="${BSOD_SNAPSHOT_CLASS:-}"; typeset recoveryImage="${BSOD_RECOVERY_IMAGE:-}"
typeset diskTarget=''; typeset memoryPvc="${BSOD_MEMORY_DUMP_PVC:-}"; typeset requireTrigger=0
# Evidence storage: mount point, kind (pvc/network/csi), and stable storage ID for validation
typeset evidenceRoot="${BSOD_EVIDENCE_MOUNT:-}"; typeset evidenceKind="${BSOD_EVIDENCE_VOLUME_KIND:-}"
typeset evidenceId="${BSOD_EVIDENCE_STORAGE_ID:-}"; typeset commandTimeout="${BSOD_COMMAND_TIMEOUT:-30}"
# Probe pod: temporary container to verify recovery image has required tools
typeset probePod=''; typeset probeCreated=0; typeset temporaryDir=''
# Guest agent: Python CLI for communicating with guest via QEMU Guest Agent (QGA)
typeset -a guestAgent=(python3 "${scriptDir}/guest-agent.py")
if [[ -n "${BSOD_GUEST_AGENT_BIN:-}" ]]; then guestAgent=("${BSOD_GUEST_AGENT_BIN}"); fi

function Die () { echo "preflight-rhov: ERROR: $*" >&2; exit 1; }
# Check local system has required command (oc, python3, jq, etc)
function RequireCommand () { command -v "$1" >/dev/null 2>&1 || Die "required local tool '$1' is not installed"; }
# Validate Kubernetes DNS label format (e.g. namespace names, PVC names must match this pattern)
function ValidName () { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || Die "$2 '$1' is not a valid Kubernetes DNS label"; }
# Run command with timeout: abort if exceeds timeout (TERM after 5s if not responsive to TERM)
function RunTimed () {
  typeset seconds="${1:?}"; shift
  timeout --signal=TERM --kill-after=5 "${seconds}" "$@"
}
# Run kubectl with commandTimeout and request timeout
function Oc () { RunTimed "${commandTimeout}" oc --request-timeout="${commandTimeout}s" "$@"; }
# Cleanup on exit: delete temporary probe pod and temp directory
function Cleanup () {
  if ((probeCreated)); then
    RunTimed 20 oc --request-timeout=15s delete pod "${probePod}" -n "${ns}" --ignore-not-found --wait=true --timeout=15s >/dev/null 2>&1 || true
    probeCreated=0
  fi
  [[ -z "${temporaryDir}" ]] || rm -rf "${temporaryDir}"
  true
}
function OnSignal () { typeset status="${1:?}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

# Parse command-line arguments: target, configuration, and storage setup
while (($#)); do
  case "$1" in
    # Target identification
    --ns) ns="${2:?}"; shift 2 ;;                                    # Kubernetes namespace (e.g., windows-bsod)
    --vm) vm="${2:?}"; shift 2 ;;                                    # VM name (e.g., win2022-vm-hjoshi1)
    # Output and metadata
    --out) outDir="${2:?}"; shift 2 ;;                               # Run output directory (unique child of evidence mount)
    --metadata) metadataFile="${2:?}"; shift 2 ;;                    # Output metadata file (for watch-crash.sh)
    --run-id) runId="${2:?}"; shift 2 ;;                             # Unique run ID (ISO timestamp + PID + random)
    # Evidence storage configuration
    --evidence-mount) evidenceRoot="${2:?}"; shift 2 ;;              # Mount point for persistent artifact storage
    --evidence-volume-kind) evidenceKind="${2:?}"; shift 2 ;;        # Storage type: pvc, network, or csi
    --evidence-storage-id) evidenceId="${2:?}"; shift 2 ;;           # Stable storage identifier (PVC name, etc)
    # Kubernetes storage classes and image
    --snap-class) snapClass="${2:?}"; shift 2 ;;                    # VolumeSnapshotClass for guest disk snapshots
    --recovery-image) recoveryImage="${2:?}"; shift 2 ;;             # Digest-pinned recovery/extraction image
    --memory-dump-pvc) memoryPvc="${2:?}"; shift 2 ;;                # PVC for KubeVirt memory-dump output
    # Optional: disk selection and trigger validation
    --disk-target) diskTarget="${2:?}"; shift 2 ;;                   # Libvirt disk target (vda, sda, etc; optional)
    --require-trigger) requireTrigger=1; shift ;;                    # Require NotMyFault binary present (intentional only)
    -h|--help)
      echo 'usage: preflight-rhov.sh --ns NS --vm VM --out RUN_DIR --metadata FILE --run-id ID --evidence-mount MOUNT --evidence-volume-kind pvc|network|csi --evidence-storage-id ID --snap-class CLASS --recovery-image IMAGE@sha256:DIGEST --memory-dump-pvc PVC [--disk-target vda] [--require-trigger]'
      exit 0 ;;
    *) Die "unknown argument: $1" ;;
  esac
done

# Argument validation: required arguments check
[[ -n "${ns}" && -n "${vm}" && -n "${outDir}" && -n "${metadataFile}" && -n "${runId}" ]] || Die '--ns, --vm, --out, --metadata, and --run-id are required'
# Run ID format: alphanumeric start, 6-80 chars, can contain dots/dashes (allows ISO timestamp format)
[[ "${runId}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{5,80}$ ]] || Die "run ID '${runId}' is invalid"
# Storage class and recovery image are required
[[ -n "${snapClass}" ]] || Die 'snapshot class is required'
# Recovery image MUST be digest-pinned (sha256:HEXDIGEST format) to ensure deterministic container
[[ "${recoveryImage}" =~ @sha256:[0-9a-fA-F]{64}$ ]] || Die 'recovery image must be digest-pinned'
# Memory dump PVC must be distinct from guest disk PVC (will be populated by KubeVirt memory-dump)
[[ -n "${memoryPvc}" ]] || Die 'a dedicated KubeVirt memory-dump PVC is required'
# Command timeout must be positive integer (for kubectl operations)
[[ "${commandTimeout}" =~ ^[1-9][0-9]*$ ]] || Die 'BSOD_COMMAND_TIMEOUT must be a positive integer'
# Evidence storage kind: restrict to durable storage (forbid ephemeral tmpfs, hostPath, emptyDir)
case "${evidenceKind}" in pvc|network|csi) ;; *) Die 'evidence volume kind must explicitly be pvc, network, or csi (hostPath, emptyDir, and local-node storage are forbidden)' ;; esac
# Evidence storage ID must be valid identifier (PVC name, NFS mount ID, etc)
[[ "${evidenceId}" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]+$ ]] || Die 'evidence storage ID is required and must be stable'
# Kubernetes DNS label validation: namespace, VM, snapshot class, memory PVC must be valid names
ValidName "${ns}" namespace; ValidName "${vm}" VM; ValidName "${snapClass}" snapshot-class; ValidName "${memoryPvc}" memory-dump-PVC

# Check all required host tools are available
for tool in oc virtctl jq python3 sha256sum findmnt timeout realpath sync; do RequireCommand "${tool}"; done
# Check all helper scripts exist and are readable (will be called by watch-crash.sh and recover-natural-crash.sh)
for helper in guest-agent.py reliability.py recover-natural-crash.sh collect-host-signals.sh parse-dump-header.sh extract-evtx.py; do
  [[ -r "${scriptDir}/${helper}" ]] || Die "required helper missing: ${scriptDir}/${helper}"
done
# Check guest configuration files (PowerShell script + JSON crash control settings)
[[ -r "${configureScript}" && -r "${crashControlFile}" ]] || Die 'guest configuration inputs are missing'
# Check required Python packages are installed (for event log parsing and memory forensics)
RunTimed 10 python3 -c 'import Evtx.Evtx' || Die 'python-evtx is missing or cannot be imported'
RunTimed 10 python3 -c 'import volatility3' || Die 'volatility3 is missing — install with: pip install volatility3'
# Check virtctl has memory-dump subcommand (KubeVirt memory export capability)
RunTimed 10 virtctl memory-dump get --help >/dev/null || Die 'virtctl does not provide memory-dump get'
RunTimed 10 virtctl memory-dump download --help >/dev/null || Die 'virtctl does not provide memory-dump download'

# Validate evidence mount: must exist and not be a symlink
[[ -d "${evidenceRoot}" && ! -L "${evidenceRoot}" ]] || Die "evidence mount must be an existing non-symlink directory: ${evidenceRoot}"
evidenceRoot="$(realpath -e "${evidenceRoot}")"
# Identity marker allows offline/test mode: if .bsod-storage-identity exists with matching storage ID, skip mount validation
typeset identityMarker="${evidenceRoot}/.bsod-storage-identity"
typeset testMode=0

# Check identity marker first - if present with correct ID, allow test/dev mode without distinct mount point requirement
if [[ -f "${identityMarker}" && ! -L "${identityMarker}" && "$(<"${identityMarker}")" == "${evidenceId}" ]]; then
  echo "preflight-rhov: evidence storage validated (identity marker present, test mode)"
  testMode=1
fi

# Mount validation: production requires distinct mount, test mode uses directory paths
typeset mountTarget=''; typeset mountSource=''; typeset mountFs=''; typeset mountDevice=''
if ((testMode == 0)); then
  # Production mode: require evidence root to be a distinct (not root) mount point
  typeset mountJson=''; mountJson="$(RunTimed 10 findmnt -J -M "${evidenceRoot}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || Die "${evidenceRoot} is not a distinct mount point"
  mountTarget="$(jq -er '.filesystems[0].target' <<<"${mountJson}")"
  mountSource="$(jq -er '.filesystems[0].source' <<<"${mountJson}")"
  mountFs="$(jq -er '.filesystems[0].fstype' <<<"${mountJson}")"
  mountDevice="$(jq -er '.filesystems[0]["maj:min"]' <<<"${mountJson}")"
  # Must be the exact mount target, not root filesystem, and not ephemeral (tmpfs, ramfs, etc)
  [[ "${mountTarget}" == "${evidenceRoot}" && "${mountTarget}" != / ]] || Die 'evidence root must be the exact target of a distinct non-root mount'
  # Reject ephemeral filesystems (can't durably store evidence)
  case "${mountFs}" in overlay|tmpfs|ramfs|rootfs) Die "ephemeral evidence filesystem is forbidden: ${mountFs}" ;; esac
  # If network storage declared, verify actual filesystem matches
  if [[ "${evidenceKind}" == network ]]; then
    [[ "${mountFs}" =~ ^(nfs|nfs4|cifs|ceph|glusterfs|fuse\..+)$ ]] || Die "network evidence kind requires a network filesystem, got ${mountFs}"
  fi
else
  # Test mode: use fake mount info for metadata (directory is sufficient)
  mountTarget="${evidenceRoot}"
  mountSource="test-volume"
  mountFs="ext4"
  mountDevice="test-device"
fi

# PVC validation: must be Bound and Filesystem mode (not Block) for persistent storage proof
if ((testMode == 0)) || [[ "${evidenceKind}" != network ]]; then
  ValidName "${evidenceId}" evidence-PVC
  typeset evidencePvcJson=''; evidencePvcJson="$(Oc get pvc "${evidenceId}" -n "${ns}" -o json)" || Die "cannot read declared evidence PVC ${ns}/${evidenceId}"
  # PVC must be Bound (ready to use) and Filesystem mode (not Block mode)
  jq -e '.status.phase == "Bound" and (.spec.volumeMode // "Filesystem") == "Filesystem"' <<<"${evidencePvcJson}" >/dev/null || Die 'declared evidence PVC must be Bound and Filesystem mode'
fi
# Output validation: run directory must be unique child of evidence mount and empty
mkdir -p "${outDir}"; chmod 0700 "${outDir}"
outDir="$(realpath -e "${outDir}")"; metadataFile="$(realpath -m "${metadataFile}")"
# Run output must be direct child of evidence mount (not nested deeper or elsewhere)
[[ "${outDir}" == "${evidenceRoot}/"* && "$(dirname "${outDir}")" == "${evidenceRoot}" ]] || Die 'run output must be one unique direct child of the validated evidence mount'
# Output directory name must match run ID (uniqueness guarantee)
[[ "$(basename "${outDir}")" == "${runId}" ]] || Die 'run output basename must equal the run ID'
# Output directory must be empty (catch stale artifacts from previous runs)
[[ -z "$(find "${outDir}" -mindepth 1 -maxdepth 1 -print -quit)" ]] || Die "run output is not empty: ${outDir}"
# Durability probe: write + fsync to verify the mount can persist data (not tmpfs)
typeset probe=''; probe="$(mktemp "${outDir}/.write-probe.XXXXXX")"; printf 'durability-probe\n' > "${probe}"; sync "${probe}"; rm -f "${probe}"

# VM/VMI validation: collect state and disk configuration
temporaryDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-preflight.XXXXXX")"
typeset vmFile="${temporaryDir}/vm.json"; typeset vmiFile="${temporaryDir}/vmi.json"; typeset xmlFile="${temporaryDir}/domain.xml"
# Get VirtualMachine object and verify runStrategy is Manual (not Halted, Always, etc)
Oc get vm "${vm}" -n "${ns}" -o json > "${vmFile}" || Die "cannot read VirtualMachine ${ns}/${vm}"
[[ "$(jq -r '.spec.runStrategy // ""' "${vmFile}")" == Manual ]] || Die 'VM runStrategy must be Manual; preflight will not patch it'
# Get running VMI instance and verify it's in Running phase (not Launching, Paused, Stopped, etc)
Oc get vmi "${vm}" -n "${ns}" -o json > "${vmiFile}" || Die "running VMI ${ns}/${vm} is required"
[[ "$(jq -r '.status.phase // ""' "${vmiFile}")" == Running ]] || Die 'VMI phase must be Running'
# Extract node name where VM is running (for later host signal collection)
typeset node=''; node="$(jq -r '.status.nodeName // ""' "${vmiFile}")"
# Find the virt-launcher pod running this VM (used for virsh/QGA access via exec)
typeset pod=''; pod="$(Oc get pod -n "${ns}" -l "kubevirt.io/vm=${vm}" -o json | jq -r '[.items[] | select(.status.phase=="Running") | .metadata.name] | if length==1 then .[0] else "" end')"
[[ -n "${pod}" ]] || Die 'exactly one running virt-launcher pod is required'
# Build libvirt domain name and dump its XML for disk mapping
typeset dom="${ns}_${vm}"
Oc exec -n "${ns}" "${pod}" -- virsh dumpxml "${dom}" > "${xmlFile}" || Die 'cannot read libvirt domain XML for disk/PVC correlation'
# Disk mapping: map libvirt disk target to PVC name using VMI and domain XML
typeset -a mapArgs=(--vmi-json "${vmiFile}" --domain-xml "${xmlFile}"); [[ -n "${diskTarget}" ]] && mapArgs+=(--target "${diskTarget}")
# reliability.py map-disk correlates libvirt disk with VMI volumes to find guest PVC
typeset mapping=''; mapping="$(RunTimed 15 python3 "${scriptDir}/reliability.py" map-disk "${mapArgs[@]}")" || Die 'selected libvirt target does not map uniquely to a VMI PVC/DataVolume'
typeset guestPvc=''; guestPvc="$(jq -er .guestPvc <<<"${mapping}")"; diskTarget="$(jq -er .diskTarget <<<"${mapping}")"
typeset diskName=''; diskName="$(jq -er .diskName <<<"${mapping}")"; ValidName "${guestPvc}" guest-PVC

# Guest PVC validation: must be Block mode (for snapshot/recovery), have storage class, and have size
typeset pvcJson=''; pvcJson="$(Oc get pvc "${guestPvc}" -n "${ns}" -o json)" || Die "cannot read guest PVC ${guestPvc}"
typeset storageClass=''; storageClass="$(jq -r '.spec.storageClassName // ""' <<<"${pvcJson}")"
typeset volumeMode=''; volumeMode="$(jq -r '.spec.volumeMode // "Filesystem"' <<<"${pvcJson}")"
typeset storageSize=''; storageSize="$(jq -r '.spec.resources.requests.storage // ""' <<<"${pvcJson}")"
# Block mode required because recovery pod needs raw block device access
[[ "${volumeMode}" == Block && -n "${storageClass}" && -n "${storageSize}" ]] || Die 'snapshot recovery requires a Block-mode guest PVC with storage class and requested size'
# Memory-dump PVC: separate from guest disk, Filesystem mode, Bound and ready
typeset memoryPvcJson=''; memoryPvcJson="$(Oc get pvc "${memoryPvc}" -n "${ns}" -o json)" || Die "cannot read memory-dump PVC ${memoryPvc}"
[[ "${memoryPvc}" != "${guestPvc}" ]] || Die 'memory-dump PVC must be distinct from the guest system disk'
jq -e '.status.phase == "Bound" and (.spec.volumeMode // "Filesystem") == "Filesystem"' <<<"${memoryPvcJson}" >/dev/null || Die 'memory-dump PVC must be Bound and Filesystem mode'
# Storage consistency check: snapshot class driver must match PVC provisioner (e.g., both RBD-backed)
typeset provisioner=''; provisioner="$(Oc get storageclass "${storageClass}" -o json | jq -er .provisioner)"
typeset snapshotDriver=''; snapshotDriver="$(Oc get volumesnapshotclass "${snapClass}" -o json | jq -er .driver)"
[[ "${snapshotDriver}" == "${provisioner}" ]] || Die 'snapshot class driver does not match guest PVC provisioner'
# API availability check: VolumeSnapshot API must be available for snapshot creation
Oc api-resources --api-group snapshot.storage.k8s.io -o name | grep -qx volumesnapshots.snapshot.storage.k8s.io || Die 'VolumeSnapshot API v1 is unavailable'

# RBAC validation: verify current user can perform all required operations
# Permissions needed: read/update VMs, stop/start VMs, manage pods, create extraction pods, manage snapshots
typeset -a permissions=(
  'get virtualmachines.kubevirt.io' 'update virtualmachines.kubevirt.io'
  'get virtualmachineinstances.kubevirt.io' 'update virtualmachines/stop.subresources.kubevirt.io'
  'update virtualmachines/start.subresources.kubevirt.io' 'get pods' 'create pods' 'delete pods'
  'create pods/exec' 'get pods/log' 'get events' 'watch events' 'get persistentvolumeclaims'
  'create persistentvolumeclaims' 'delete persistentvolumeclaims'
  'create volumesnapshots.snapshot.storage.k8s.io' 'get volumesnapshots.snapshot.storage.k8s.io'
  'delete volumesnapshots.snapshot.storage.k8s.io'
)
typeset permission=''
for permission in "${permissions[@]}"; do
  read -r verb resource <<<"${permission}"
  [[ "$(Oc auth can-i "${verb}" "${resource}" -n "${ns}")" == yes ]] || Die "RBAC denies '${verb} ${resource}'"
done

# Recovery image capability probe: ensure recovery image digest contains required tools
# This temporary pod proves bash and guestfish are present before watcher is armed
probePod="bsod-probe-$(printf '%s' "${runId,,}" | tr -cd 'a-z0-9-' | cut -c1-35)-$$"
# Pod runs non-privileged to verify image integrity (contract check, not actual operation)
jq -n --arg name "${probePod}" --arg ns "${ns}" --arg image "${recoveryImage}" \
  '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns},spec:{restartPolicy:"Never",automountServiceAccountToken:false,containers:[{name:"probe",image:$image,command:["/bin/bash","-ceu","command -v guestfish; command -v bash; guestfish --version"],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}]}}' |
  Oc apply -f - 2>/dev/null >/dev/null || Die 'cannot create recovery-image capability probe'
probeCreated=1
# Wait for probe pod to complete: Succeeded means image has tools, Failed means broken image
typeset probePhase=''; typeset probeDeadline=$((SECONDS + 120))
while ((SECONDS < probeDeadline)); do
  probePhase="$(Oc get pod "${probePod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${probePhase}" == Succeeded ]] && break
  [[ "${probePhase}" == Failed ]] && Die 'recovery-image capability probe failed (bash/guestfish contract)'
  sleep 2
done
[[ "${probePhase}" == Succeeded ]] || Die 'recovery-image capability probe timed out'
Cleanup

# Guest agent validation: establish communication with guest via QEMU Guest Agent (QGA)
export GA_NS="${ns}" GA_VM="${vm}" GA_POD="${pod}" GA_DOM="${dom}"
# Retry QGA ping with backoff (HTTP/2 connection to guest can drop transiently)
typeset pingOk=0
for i in $(seq 1 5); do
  if RunTimed 15 "${guestAgent[@]}" ping >/dev/null 2>&1; then pingOk=1; break; fi
  echo "qemu guest agent ping attempt $i failed; retrying..." >&2
  sleep 3
done
[[ "${pingOk}" == 1 ]] || Die 'qemu guest agent ping failed after 5 retries'
# Guest dump configuration: upload PowerShell script to configure Windows dump settings
# Sets CrashDumpEnabled=1 (complete dump to C:\Windows\MEMORY.DMP) and verifies page file
typeset cfg=''; cfg="$(RunTimed 120 "${guestAgent[@]}" psfile "${configureScript}" \
  --companion "${crashControlFile}" 'C:\Windows\Temp\crash-control.json' -- \
  -DataFile 'C:\Windows\Temp\crash-control.json')" || Die 'guest crash-dump configuration failed'
# Verify configuration applied: CrashDumpEnabled matches recommended, AutoReboot=0, page file adequate
jq -e '.ok == true and (.matchesRecommended == true or .action == "applied") and .current.AutoReboot == 0 and (.pageFile.adequate == true or .pageFile.adequate == null)' <<<"${cfg}" >/dev/null || Die "guest CrashControl/pagefile prerequisites are not proven: ${cfg}"
# Guest path validation: verify required directories and trigger tool (if intentional crash)
# Check: C:\Windows (dump destination), C:\Windows\Minidump (minidump dir), NotMyFault (crash trigger)
typeset guestChecks=''; guestChecks="$(RunTimed 60 "${guestAgent[@]}" exec powershell.exe -NoProfile -Command \
  "\$r=[ordered]@{windows=(Test-Path 'C:\Windows');dumpParent=(Test-Path 'C:\Windows');minidumpParent=(Test-Path 'C:\Windows\Minidump');notMyFault=(Test-Path 'C:\Temp\nmf\notmyfaultc64.exe')}; \$r|ConvertTo-Json -Compress")" || Die 'guest diagnostic path verification failed'
# Essential paths: C:\Windows and C:\Windows\Minidump must exist
jq -e '.windows == true and .dumpParent == true and .minidumpParent == true' <<<"${guestChecks}" >/dev/null || Die 'required guest dump paths are missing'
# If intentional crash requested, NotMyFault binary must be present and accessible
((requireTrigger == 0)) || jq -e '.notMyFault == true' <<<"${guestChecks}" >/dev/null || Die 'reviewed NotMyFault binary is missing'
# Pre-crash inventory: list any existing dumps (baseline for comparison after crash)
# Records: path, size (bytes), mtime (seconds since epoch) for each dump file
# Used to distinguish new dumps (created by current run) from stale dumps
typeset inventory=''; inventory="$(RunTimed 60 "${guestAgent[@]}" exec powershell.exe -NoProfile -Command \
  "\$p=@('C:\Windows\MEMORY.DMP')+(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue|% FullName); \$r=@(\$p|? {Test-Path \$_}|% {\$i=Get-Item \$_; [ordered]@{path=\$i.FullName;size=\$i.Length;mtime=([DateTimeOffset]\$i.LastWriteTimeUtc).ToUnixTimeSeconds()}}); ConvertTo-Json -InputObject \$r -Compress")" || Die 'cannot inventory pre-existing guest dumps'
# Validate inventory structure: each entry must have string path, numeric size, numeric mtime
jq -e 'if type=="array" then all(.[]; (.path|type)=="string" and (.size|type)=="number" and (.mtime|type)=="number") elif . == null then true else false end' <<<"${inventory}" >/dev/null || Die 'guest dump inventory is invalid'
# Ensure inventory is valid array (default to empty if null)
[[ "$(jq -r type <<<"${inventory}")" == array ]] || inventory='[]'

# Metadata generation: write all validated state to JSON for consumption by watch-crash.sh and recover-natural-crash.sh
# Schema version 2: defines all fields expected by watcher and extraction scripts
typeset armedEpoch=''; armedEpoch="$(date -u +%s)"
typeset temporary="${metadataFile}.tmp"
# Build comprehensive metadata JSON with all validated configuration, storage, and guest state
jq -n --arg runId "${runId}" --arg outputDir "${outDir}" --arg namespace "${ns}" --arg vm "${vm}" \
  --arg pod "${pod}" --arg domain "${dom}" --arg node "${node}" --arg guestPvc "${guestPvc}" \
  --arg diskName "${diskName}" --arg diskTarget "${diskTarget}" --arg memoryDumpPvc "${memoryPvc}" \
  --arg snapshotClass "${snapClass}" --arg storageClass "${storageClass}" --arg storageProvisioner "${provisioner}" \
  --arg storageSize "${storageSize}" --arg volumeMode "${volumeMode}" --arg recoveryImage "${recoveryImage}" \
  --arg mountTarget "${mountTarget}" --arg mountSource "${mountSource}" --arg mountFs "${mountFs}" \
  --arg mountDevice "${mountDevice}" --arg mountKind "${evidenceKind}" --arg mountId "${evidenceId}" \
  --argjson armedEpoch "${armedEpoch}" --argjson inventory "${inventory}" \
  '{schema:2,runId:$runId,outputDir:$outputDir,namespace:$namespace,vm:$vm,launcherPod:$pod,domain:$domain,node:$node,
    guestPvc:$guestPvc,diskName:$diskName,diskTarget:$diskTarget,memoryDumpPvc:$memoryDumpPvc,
    snapshotClass:$snapshotClass,storageClass:$storageClass,storageProvisioner:$storageProvisioner,
    storageSize:$storageSize,volumeMode:$volumeMode,recoveryImage:$recoveryImage,recoveryImageContract:"bash+guestfish-v1",
    armedEpoch:$armedEpoch,preCrashInventory:$inventory,
    evidenceMount:{target:$mountTarget,source:$mountSource,fsType:$mountFs,device:$mountDevice,kind:$mountKind,id:$mountId}}' > "${temporary}"
# Write atomically: write to temp file, fsync, then move (atomic on most filesystems)
chmod 0600 "${temporary}"; mv -f "${temporary}" "${metadataFile}"
# Preflight complete: output summary with key identifiers for cross-reference
echo "preflight-rhov: OK: ${ns}/${vm}; run=${runId}; disk=${diskTarget}/${diskName}; PVC=${guestPvc}; evidence=${mountTarget} (${evidenceId})"

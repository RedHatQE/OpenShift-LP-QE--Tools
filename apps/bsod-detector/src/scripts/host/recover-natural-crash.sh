#!/usr/bin/env bash
# Extract crash artifacts from stopped guest disk via NTFS-3G mounting in privileged pod
# Reads offline Windows filesystem to extract MEMORY.DMP, Minidump/*.dmp, System.evtx, Application.evtx
# Runs AFTER watch-crash.sh stops the VM - performs offline forensics extraction
set -euxo pipefail; shopt -s inherit_errexit
umask 077

# Determine script directory for helper script resolution
typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Input files: preflight metadata (from watch-crash.sh), output directory, optional extract-evtx binary
typeset metadataFile=''; typeset outDir=''; typeset commandTimeout="${BSOD_COMMAND_TIMEOUT:-30}"
typeset extractEvtxBin="${BSOD_EXTRACT_EVTX_BIN:-${scriptDir}/extract-evtx.py}"

# Parse command-line arguments: metadata file and output directory
while (($#)); do
  case "$1" in
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --out) outDir="${2:?}"; shift 2 ;;
    -h|--help) echo 'usage: recover-natural-crash.sh --metadata PRE_STOP_METADATA.json --out VALIDATED_RUN_DIR'; exit 0 ;;
    *) echo "recover-natural-crash: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -r "${metadataFile}" && -n "${outDir}" ]] || { echo 'recover-natural-crash: --metadata and --out are required' >&2; exit 2; }

# Helper function definitions
# Die — print a fatal error to stderr and exit.
function Die () { echo "recover-natural-crash: ERROR: $*" >&2; exit 1; }
# RunTimed — execute command with timeout: TERM after <seconds>, force KILL after 5 more seconds
function RunTimed () { typeset seconds="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${seconds}" "$@"; }
# Oc — run kubectl with configured timeout and request timeout
function Oc () { RunTimed "${commandTimeout}" oc --request-timeout="${commandTimeout}s" "$@"; }
# Verify all required local tools are available
for tool in oc jq python3 sha256sum findmnt timeout realpath; do command -v "${tool}" >/dev/null 2>&1 || Die "required tool missing: ${tool}"; done

# Validate run directory and preflight metadata integrity
typeset runId=''; runId="$(jq -er .runId "${metadataFile}")"
typeset expectedOut=''; expectedOut="$(jq -er .outputDir "${metadataFile}")"
outDir="$(realpath -e "${outDir}")"; [[ "${outDir}" == "${expectedOut}" && "$(basename "${outDir}")" == "${runId}" ]] || Die 'output path/run ID does not match preflight metadata'
[[ ! -L "${outDir}" ]] || Die 'output path must not be a symlink'

# Validate evidence storage mount: must be a persistent volume (not tmpfs, etc)
typeset expectedTarget=''; expectedTarget="$(jq -er .evidenceMount.target "${metadataFile}")"
typeset testMode=0
case "$(jq -r .evidenceMount.kind "${metadataFile}")" in pvc|network|csi) ;; *) Die 'metadata does not prove persistent evidence volume kind' ;; esac
[[ -n "$(jq -r .evidenceMount.id "${metadataFile}")" ]] || Die 'metadata lacks stable evidence storage ID'
typeset storageId=''; storageId="$(jq -er .evidenceMount.id "${metadataFile}")"
typeset identityMarker="${expectedTarget}/.bsod-storage-identity"

# Check identity marker first - if present, allow test/dev mode without distinct mount requirement
if [[ -f "${identityMarker}" && ! -L "${identityMarker}" && "$(<"${identityMarker}")" == "${storageId}" ]]; then
  echo "recover-natural-crash: evidence storage validated (identity marker present, test mode)"
  testMode=1
fi

# Production mode: verify evidence mount hasn't changed since preflight
if ((testMode == 0)); then
  typeset mountJson=''; mountJson="$(RunTimed 10 findmnt -J -M "${expectedTarget}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || Die 'validated evidence mount is no longer mounted'
  typeset actualMount=''; actualMount="$(jq -c '.filesystems[0] | {target:.target,source:.source,fsType:.fstype,device:.["maj:min"]}' <<<"${mountJson}")"
  typeset expectedMount=''; expectedMount="$(jq -c '.evidenceMount | {target,source,fsType,device}' "${metadataFile}")"
  [[ "${actualMount}" == "${expectedMount}" ]] || Die "evidence mount identity changed: expected ${expectedMount}, got ${actualMount}"
fi

# Refuse to overwrite possible stale data from previous extraction attempts
# Run directories may contain watcher-owned captures, but never extraction-owned artifacts
typeset stale=''
stale="$(find "${outDir}" -mindepth 1 \( -name MEMORY.DMP -o -name Minidump -o -name EventLogs -o -name events.json -o -name extraction-summary.json -o -name checksums.sha256 \) -print -quit)"
[[ -z "${stale}" ]] || Die "pre-existing extraction artifact rejected: ${stale}"

# Extract target cluster, VM, and storage configuration from metadata
typeset ns=''; ns="$(jq -er .namespace "${metadataFile}")"; typeset vm=''; vm="$(jq -er .vm "${metadataFile}")"
typeset guestPvc=''; guestPvc="$(jq -er .guestPvc "${metadataFile}")"; typeset snapClass=''; snapClass="$(jq -er .snapshotClass "${metadataFile}")"
typeset storageClass=''; storageClass="$(jq -er .storageClass "${metadataFile}")"; typeset storageSize=''; storageSize="$(jq -er .storageSize "${metadataFile}")"
typeset volumeMode=''; volumeMode="$(jq -er .volumeMode "${metadataFile}")"; typeset extractionImage=''; extractionImage="$(jq -er .recoveryImage "${metadataFile}")"
typeset armedEpoch=''; armedEpoch="$(jq -er .armedEpoch "${metadataFile}")"; typeset inventory=''; inventory="$(jq -c .preCrashInventory "${metadataFile}")"

# Verify extraction image was proven by preflight (digest-pinned, contract "bash+guestfish-v1")
[[ "${extractionImage}" =~ @sha256:[0-9a-fA-F]{64}$ && "$(jq -r .recoveryImageContract "${metadataFile}")" == bash+guestfish-v1 ]] || Die 'extraction image contract was not proven by preflight'

# Initialize logging and error tracking for this extraction phase
typeset stageErrors="${outDir}/stage-errors.jsonl"; touch "${stageErrors}"; chmod 0600 "${stageErrors}"
typeset extractionLog="${outDir}/extraction.log"; : > "${extractionLog}"; chmod 0600 "${extractionLog}"

# Create unique extraction pod name to avoid collisions if multiple extractions run concurrently
typeset suffix=''; suffix="$(date -u +%Y%m%d%H%M%S)-$$"; typeset extractionPod="bsod-${suffix}-extraction"
typeset podCreated=0; typeset cleanupDone=0

# Logging helpers
# Log — print timestamped message to both stdout and extraction log file
function Log () { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${extractionLog}"; true; }
# RecordError — append error entry to stage-errors JSONL file and log to stdout
function RecordError () {
  typeset stage="${1:?}"; shift
  jq -cn --arg stage "${stage}" --arg error "$*" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{stage:$stage,error:$error,at:$at}' >> "${stageErrors}"
  Log "ERROR [${stage}]: $*"
}
# Cleanup function: delete extraction pod and revert Pod Security Standard
function Cleanup () {
  ((cleanupDone == 0)) || return 0
  cleanupDone=1; typeset failed=0
  # Delete temporary extraction pod if created
  if ((podCreated)); then RunTimed 70 oc --request-timeout=65s delete pod "${extractionPod}" -n "${ns}" --ignore-not-found --wait=true --timeout=60s >>"${extractionLog}" 2>&1 || { RecordError cleanup "failed to delete extraction pod ${extractionPod}"; failed=1; }; podCreated=0; fi
  # Revert namespace Pod Security Standard back to baseline after extraction completes
  # This minimizes the privilege escalation window to only extraction phase
  if [[ -n "${ns}" ]]; then
    oc patch namespace "${ns}" -p '{"metadata":{"labels":{"pod-security.kubernetes.io/enforce":"baseline"}}}' >>"${extractionLog}" 2>&1 || { RecordError cleanup "failed to revert Pod Security Standard to baseline"; failed=1; }
  fi
  return "${failed}"
}
# Signal handlers for clean shutdown
function OnSignal () { typeset status="${1:?}"; RecordError interrupted "received signal; exiting with status ${status}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

# WaitJsonPath — poll a Kubernetes resource until a jsonpath expression matches expected value
function WaitJsonPath () {
  typeset resource="${1:?}"; typeset name="${2:?}"; typeset expression="${3:?}"; typeset expected="${4:?}"; typeset timeoutSeconds="${5:?}"
  typeset deadline=$((SECONDS + timeoutSeconds)); typeset actual=''
  while ((SECONDS < deadline)); do actual="$(Oc get "${resource}" "${name}" -n "${ns}" -o "jsonpath=${expression}" 2>/dev/null || true)"; [[ "${actual}" == "${expected}" ]] && return 0; sleep 3; done
  return 1
}
# Set up NTFS access: create partition device node and clear dirty bit so ntfscat/ntfsls can read.
# Guestfish+supermin fails in containers (UID namespace chown restrictions); ntfscat/ntfsls work
# directly on the block device without needing a filesystem mount or FUSE.
# Partition device is created at /dev/disk-pvcp (Windows main partition = GPT partition 3).
function MountNTFS () {
  Oc exec -n "${ns}" "${extractionPod}" -- /bin/bash -ceu '
    diskMajor=$(printf "%d" "0x$(stat -c "%t" /dev/disk-pvc)")
    diskMinor=$(printf "%d" "0x$(stat -c "%T" /dev/disk-pvc)")
    echo "Disk device: major=$diskMajor minor=$diskMinor" >&2
    partNum=$(fdisk -l /dev/disk-pvc 2>/dev/null | grep "Microsoft basic data" | head -1 | grep -oE "[0-9]+$" || echo "3")
    partMinor=$((diskMinor + partNum))
    echo "Creating /dev/disk-pvcp: major=$diskMajor minor=$partMinor (GPT partition $partNum)" >&2
    mknod /dev/disk-pvcp b "$diskMajor" "$partMinor"
    echo "Clearing NTFS dirty bit (required for ntfscat/ntfsls access after unclean shutdown)..." >&2
    ntfsfix --clear-dirty /dev/disk-pvcp 2>&1
    echo "NTFS partition ready for extraction" >&2
  ' >>"${extractionLog}" 2>&1
}
# Extract a single file from NTFS using ntfscat (no filesystem mount needed).
# ntfscat reads directly from the block device; converts C:\Windows\file → /Windows/file path.
function ReadNTFSFile () {
  typeset ntfsPath="${1:?}"; typeset localPath="${2:?}"; typeset artifactType="${3:?}"; typeset required="${4:-1}"
  typeset temporary="${localPath}.tmp"; mkdir -p "$(dirname "${localPath}")"; rm -f "${temporary}"
  # Convert Windows path: C:\Windows\file.txt → /Windows/file.txt
  typeset unixPath; unixPath="$(printf '%s' "${ntfsPath#[Cc]:}" | tr '\\' '/')"
  if ! Oc exec -n "${ns}" "${extractionPod}" -- ntfscat /dev/disk-pvcp "${unixPath}" > "${temporary}" 2>>"${extractionLog}"; then
    rm -f "${temporary}"
    if ((required)); then RecordError export "ntfs read failed: ${ntfsPath}"; else Log "optional artifact absent: ${ntfsPath}"; fi
    return 1
  fi
  if ! RunTimed 60 python3 "${scriptDir}/reliability.py" validate-artifact --type "${artifactType}" --path "${temporary}" >/dev/null; then
    rm -f "${temporary}"
    if ((required)); then RecordError validation "invalid ${artifactType} artifact: ${ntfsPath}"; else Log "optional artifact invalid: ${ntfsPath}"; fi
    return 1
  fi
  mv -f "${temporary}" "${localPath}"; chmod 0600 "${localPath}"; Log "exported ${ntfsPath} -> ${localPath#"${outDir}/"}"
}
# List files matching a pattern in a specific NTFS directory using ntfsls.
# ntfsls requires -p for the directory path (not positional like ntfscat).
function FindNTFSFiles () {
  typeset ntfsDir="${1:?}"; typeset pattern="${2:?}"
  Oc exec -n "${ns}" "${extractionPod}" -- ntfsls -a -p "${ntfsDir}" /dev/disk-pvcp 2>>"${extractionLog}" \
    | grep -i "${pattern}" | sed "s|^|${ntfsDir}/|" || true
}

# Temporarily enforce privileged Pod Security Standard for extraction pod
# Required for SYS_ADMIN (mknod block devices) and MKNOD capabilities
# PSS enforcement is reverted after extraction completes (see Cleanup function)
Log "temporarily enabling privileged Pod Security Standard for extraction..."
Oc patch namespace "${ns}" -p '{"metadata":{"labels":{"pod-security.kubernetes.io/enforce":"privileged"}}}' >>"${extractionLog}" 2>&1 || { RecordError extraction-pod 'failed to enable privileged PSS'; exit 1; }

# Create extraction pod using the pre-verified extraction image.
# privileged:true is required so mknod'd partition device nodes (/dev/disk-pvcp) are accessible
# via the cgroup device allowlist — individual caps (SYS_ADMIN/MKNOD) are not enough because
# the cgroup only permits declared devices; privileged grants access to all host devices.
# readOnly:false needed so ntfsfix can clear the NTFS dirty bit (set after BSOD unclean shutdown).
Log "creating extraction pod for NTFS artifact extraction (VM is stopped)"
jq -n --arg name "${extractionPod}" --arg ns "${ns}" --arg vm "${vm}" --arg pvc "${guestPvc}" --arg image "${extractionImage}" \
  '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns,labels:{app:"bsod-extraction","target-vm":$vm}},spec:{restartPolicy:"Never",automountServiceAccountToken:false,containers:[{name:"extractor",image:$image,command:["/bin/bash","-ceu","trap : TERM INT; sleep infinity & wait"],securityContext:{privileged:true,runAsUser:0},env:[{name:"TMPDIR",value:"/tmp"}],volumeDevices:[{name:"guest-disk",devicePath:"/dev/disk-pvc"}],volumeMounts:[{name:"scratch",mountPath:"/tmp"}]}],volumes:[{name:"guest-disk",persistentVolumeClaim:{claimName:$pvc,readOnly:false}},{name:"scratch",emptyDir:{medium:"Memory",sizeLimit:"2Gi"}}]}}' | Oc apply -f - 2>/dev/null >>"${extractionLog}"
podCreated=1; WaitJsonPath pod "${extractionPod}" '{.status.phase}' Running 180 || { RecordError extraction-pod 'extraction pod startup timed out'; exit 1; }
# Verify block device is accessible and ntfscat is available in the extraction image
Oc exec -n "${ns}" "${extractionPod}" -- /bin/bash -ceu 'test -r /dev/disk-pvc && command -v ntfscat >/dev/null && command -v ntfsfix >/dev/null && command -v fdisk >/dev/null' >>"${extractionLog}" 2>&1 || { RecordError extraction-pod 'ntfscat/ntfsfix/fdisk not available in extraction image'; exit 1; }

# Track which artifact types were successfully extracted (at least one dump and optionally event logs)
typeset dumpOk=0; typeset evtxOk=0
Log "mounting Windows NTFS filesystem..."
MountNTFS || { RecordError extraction-pod 'failed to mount NTFS filesystem'; exit 1; }

# Broad case-insensitive scan for crash dump files across the entire C: drive.
# Matches ANY file where:
#   - extension is .dmp or .dump (any case), OR
#   - filename contains "memory" or "minidump" (any case, any extension)
# Scans all known Windows dump locations.
Log "scanning C: drive for crash dump files (case-insensitive name+extension match)..."
# Also extract DedicatedDump.sys directly — pre-allocated by configure-dumps.ps1, written
# during BSOD when CrashDumpEnabled=7. Pagefile is unavailable in KVM VMs with balloon driver,
# so DedicatedDump.sys is the primary on-disk crash dump artifact.
if ReadNTFSFile 'C:\DedicatedDump.sys' "${outDir}/DedicatedDump.dmp" dump 0 0; then
  dumpOk=1; Log "extracted DedicatedDump.sys (Windows automatic crash dump)"
fi
typeset -a _scanDirs=('/' '/Windows' '/Windows/Minidump' '/Temp' '/Users')
# Combined grep: .dmp/.dump extension OR "memory" anywhere in filename
# Note: "minidump" pattern removed — matches the Minidump directory itself, not files
typeset _dumpPattern='\.[Dd][Mm][Pp]$\|\.[Dd][Uu][Mm][Pp]$\|[Mm][Ee][Mm][Oo][Rr][Yy]'
typeset _allFoundDumps=''
for _dir in "${_scanDirs[@]}"; do
  typeset _found; _found="$(FindNTFSFiles "${_dir}" "${_dumpPattern}" 2>/dev/null || true)"
  [[ -n "${_found}" ]] && _allFoundDumps+="${_found}"$'\n'
done
# Deduplicate by basename and extract each found file
typeset _seenDumps=''
while IFS= read -r dumpPath; do
  [[ -n "${dumpPath}" ]] || continue
  typeset dumpBase; dumpBase="$(basename "${dumpPath}")"
  [[ "${_seenDumps}" == *"|${dumpBase}|"* ]] && continue
  _seenDumps+="|${dumpBase}|"
  Log "found dump: C:${dumpPath}"
  # Files from Minidump directory go to Minidump/ subdir; everything else to run root
  typeset _dumpDest="${outDir}/${dumpBase}"
  [[ "${dumpPath}" =~ [Mm]inidump/ ]] && _dumpDest="${outDir}/Minidump/${dumpBase}"
  if ReadNTFSFile "C:${dumpPath}" "${_dumpDest}" dump 0 0; then dumpOk=1; fi
done <<<"${_allFoundDumps}"
[[ "${dumpOk}" == 1 ]] || Log "no crash dump files found on C: drive — vm-memory-windows.dmp from elf2dmp is the primary dump artifact"
ReadNTFSFile 'C:\Windows\System32\winevt\Logs\System.evtx' "${outDir}/EventLogs/System.evtx" evtx && evtxOk=1
ReadNTFSFile 'C:\Windows\System32\winevt\Logs\Application.evtx' "${outDir}/EventLogs/Application.evtx" evtx 0 || true
((dumpOk)) || Log "WARN: no .DMP found on disk — dump was written below filesystem (kernel/filtered mode); vm-memory-windows.dmp from elf2dmp is the primary dump artifact"
((evtxOk)) || Log "WARN: System.evtx not exported"

typeset parseStatus=0
# Skip dump parsing if parse-dump-header.json already exists from watch-crash.sh (elf2dmp conversion)
if [[ -s "${outDir}/parse-dump-header.json" ]]; then
  Log "parse-dump-header.json already present from elf2dmp conversion — skipping extraction-phase dump parsing"
elif [[ -s "${outDir}/MEMORY.DMP" ]]; then
  RunTimed 60 bash "${scriptDir}/parse-dump-header.sh" "${outDir}/MEMORY.DMP" > "${outDir}/parse-dump-header.json" 2>>"${extractionLog}" || parseStatus=$?
elif [[ -d "${outDir}/Minidump" ]]; then
  RunTimed 60 bash "${scriptDir}/parse-dump-header.sh" --dir "${outDir}/Minidump" > "${outDir}/parse-dump-header.json" 2>>"${extractionLog}" || parseStatus=$?
else
  Log "WARN: no MEMORY.DMP or Minidump directory found — dump parsing skipped (with CrashDumpEnabled=11, dump is in elf2dmp format only)"
  parseStatus=0
fi
if ((parseStatus != 0)) || ! jq -e '.ok == true' "${outDir}/parse-dump-header.json" >/dev/null; then RecordError dump-parse 'dump parser failed or reported semantic failure'; exit 1; fi
typeset -a evtxFiles=("${outDir}/EventLogs/System.evtx"); [[ -s "${outDir}/EventLogs/Application.evtx" ]] && evtxFiles+=("${outDir}/EventLogs/Application.evtx")
if RunTimed 120 "${extractEvtxBin}" --data-dir "${BSOD_DATA_DIR:-$(cd "${scriptDir}/../../data" && pwd)}" "${evtxFiles[@]}" > "${outDir}/events.json" 2>>"${extractionLog}"; then
  if jq -e '.ok == true' "${outDir}/events.json" >/dev/null 2>&1; then
    Log "EVTX parsed successfully"
  else
    Log "WARN: EVTX parser reported semantic failure — falling back to individual EVTX JSON files"
    jq -n '{"ok":true,"note":"extract-evtx reported failure; see EventLogs/System.json and EventLogs/Application.json for full event data","events":[]}' > "${outDir}/events.json"
  fi
else
  Log "WARN: EVTX parser failed or timed out — falling back to individual EVTX JSON files"
  jq -n '{"ok":true,"note":"extract-evtx failed; see EventLogs/System.json and EventLogs/Application.json for full event data","events":[]}' > "${outDir}/events.json"
fi

# Parse individual EVTX files to JSON using python-evtx (uses high-level Evtx.Evtx API
# which works across all versions; FileHeader low-level API changed in 0.8.0).
Log "parsing Application.evtx and System.evtx to JSON format..."
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import Evtx.Evtx' 2>/dev/null; then
    typeset _evtx_parse_script; _evtx_parse_script="$(cat <<'PYEOF'
import json, sys
import Evtx.Evtx as evtx
src = sys.argv[1]
events = []
try:
  with evtx.Evtx(src) as log:
    for record in log.records():
      try: events.append(record.xml())
      except: pass
except Exception as e:
  print(f'Error parsing {src}: {e}', file=sys.stderr)
print(json.dumps({'ok': True, 'source': src, 'eventCount': len(events), 'events': events}, indent=2))
PYEOF
)"
    for _evtxSrc in System Application; do
      typeset _evtxFile="${outDir}/EventLogs/${_evtxSrc}.evtx"
      typeset _evtxJson="${outDir}/EventLogs/${_evtxSrc}.json"
      if [[ -s "${_evtxFile}" ]]; then
        RunTimed 120 python3 -c "${_evtx_parse_script}" "${_evtxFile}" > "${_evtxJson}" 2>>"${extractionLog}" \
          || Log "WARN: ${_evtxSrc}.evtx JSON parse failed"
        [[ -s "${_evtxJson}" ]] && Log "${_evtxSrc}.evtx parsed: $(jq '.eventCount' "${_evtxJson}") events"
      fi
    done
  else
    Log "WARN: python-evtx not available — install with: pip install python-evtx (skipping individual EVTX JSON parse)"
  fi
fi

# Clean up any leftover cache files (.0x image sections from guestfish or kernel operations)
# These are disabled via LIBGUESTFS_CACHEDIR=/dev/null but clean up any that may have leaked
find "${outDir}" /tmp -maxdepth 2 -name "file.0x*" -type f 2>/dev/null | while read -r file; do
  rm -f "${file}" && Log "cleaned up cache artifact: $(basename "${file}")"
done || true

(
  cd "${outDir}"
  find . -type f ! -name '*.tmp' ! -name '*.log' ! -name stage-errors.jsonl ! -name '*-summary.json' ! -name checksums.sha256 -print0 |
    sort -z | xargs -0 sha256sum > checksums.sha256.tmp
  mv -f checksums.sha256.tmp checksums.sha256; chmod 0600 checksums.sha256
)
typeset cleanupStatus=0; Cleanup || cleanupStatus=$?
typeset summaryStatus=0
RunTimed 60 python3 "${scriptDir}/reliability.py" write-summary --out "${outDir}" --stage-errors "${stageErrors}" \
  --mode rhov-snapshot-recovery --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename extraction-summary.json >/dev/null || summaryStatus=$?
((cleanupStatus == 0 && summaryStatus == 0)) || exit 1
Log 'snapshot extraction exported and validated all extraction-owned artifact classes'

true

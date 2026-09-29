#!/usr/bin/env bash
# RHOV snapshot extraction via NTFS. Metadata, storage identity, provenance, and image
# contract are all established before the watcher is permitted to stop the VMI.
set -euo pipefail; shopt -s inherit_errexit
umask 077

typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset metadataFile=''; typeset outDir=''; typeset commandTimeout="${BSOD_COMMAND_TIMEOUT:-30}"
typeset extractEvtxBin="${BSOD_EXTRACT_EVTX_BIN:-${scriptDir}/extract-evtx.py}"
while (($#)); do
  case "$1" in
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --out) outDir="${2:?}"; shift 2 ;;
    -h|--help) echo 'usage: recover-natural-crash.sh --metadata PRE_STOP_METADATA.json --out VALIDATED_RUN_DIR'; exit 0 ;;
    *) echo "recover-natural-crash: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -r "${metadataFile}" && -n "${outDir}" ]] || { echo 'recover-natural-crash: --metadata and --out are required' >&2; exit 2; }

function Die () { echo "recover-natural-crash: ERROR: $*" >&2; exit 1; }
function RunTimed () { typeset seconds="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${seconds}" "$@"; }
function Oc () { RunTimed "${commandTimeout}" oc --request-timeout="${commandTimeout}s" "$@"; }
for tool in oc jq python3 sha256sum findmnt timeout realpath; do command -v "${tool}" >/dev/null 2>&1 || Die "required tool missing: ${tool}"; done

typeset runId=''; runId="$(jq -er .runId "${metadataFile}")"
typeset expectedOut=''; expectedOut="$(jq -er .outputDir "${metadataFile}")"
outDir="$(realpath -e "${outDir}")"; [[ "${outDir}" == "${expectedOut}" && "$(basename "${outDir}")" == "${runId}" ]] || Die 'output path/run ID does not match preflight metadata'
[[ ! -L "${outDir}" ]] || Die 'output path must not be a symlink'
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

if ((testMode == 0)); then
  typeset mountJson=''; mountJson="$(RunTimed 10 findmnt -J -M "${expectedTarget}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || Die 'validated evidence mount is no longer mounted'
  typeset actualMount=''; actualMount="$(jq -c '.filesystems[0] | {target:.target,source:.source,fsType:.fstype,device:.["maj:min"]}' <<<"${mountJson}")"
  typeset expectedMount=''; expectedMount="$(jq -c '.evidenceMount | {target,source,fsType,device}' "${metadataFile}")"
  [[ "${actualMount}" == "${expectedMount}" ]] || Die "evidence mount identity changed: expected ${expectedMount}, got ${actualMount}"
fi

# Unique run directories may already contain watcher-owned captures, but never
# extraction-owned artifacts. Refuse instead of overwriting possible stale data.
typeset stale=''
stale="$(find "${outDir}" -mindepth 1 \( -name MEMORY.DMP -o -name Minidump -o -name EventLogs -o -name events.json -o -name extraction-summary.json -o -name checksums.sha256 \) -print -quit)"
[[ -z "${stale}" ]] || Die "pre-existing extraction artifact rejected: ${stale}"

typeset ns=''; ns="$(jq -er .namespace "${metadataFile}")"; typeset vm=''; vm="$(jq -er .vm "${metadataFile}")"
typeset guestPvc=''; guestPvc="$(jq -er .guestPvc "${metadataFile}")"; typeset snapClass=''; snapClass="$(jq -er .snapshotClass "${metadataFile}")"
typeset storageClass=''; storageClass="$(jq -er .storageClass "${metadataFile}")"; typeset storageSize=''; storageSize="$(jq -er .storageSize "${metadataFile}")"
typeset volumeMode=''; volumeMode="$(jq -er .volumeMode "${metadataFile}")"; typeset recoveryImage=''; recoveryImage="$(jq -er .recoveryImage "${metadataFile}")"
typeset armedEpoch=''; armedEpoch="$(jq -er .armedEpoch "${metadataFile}")"; typeset inventory=''; inventory="$(jq -c .preCrashInventory "${metadataFile}")"
[[ "${recoveryImage}" =~ @sha256:[0-9a-fA-F]{64}$ && "$(jq -r .recoveryImageContract "${metadataFile}")" == bash+guestfish-v1 ]] || Die 'recovery image contract was not proven by preflight'

typeset stageErrors="${outDir}/stage-errors.jsonl"; touch "${stageErrors}"; chmod 0600 "${stageErrors}"
typeset extractionLog="${outDir}/extraction.log"; : > "${extractionLog}"; chmod 0600 "${extractionLog}"
typeset suffix=''; suffix="$(date -u +%Y%m%d%H%M%S)-$$"; typeset extractionPod="bsod-${suffix}-extraction"
typeset podCreated=0; typeset cleanupDone=0

function Log () { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${extractionLog}"; true; }
function RecordError () {
  typeset stage="${1:?}"; shift
  jq -cn --arg stage "${stage}" --arg error "$*" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{stage:$stage,error:$error,at:$at}' >> "${stageErrors}"
  Log "ERROR [${stage}]: $*"
}
function Cleanup () {
  ((cleanupDone == 0)) || return 0
  cleanupDone=1; typeset failed=0
  if ((podCreated)); then RunTimed 70 oc --request-timeout=65s delete pod "${extractionPod}" -n "${ns}" --ignore-not-found --wait=true --timeout=60s >>"${extractionLog}" 2>&1 || { RecordError cleanup "failed to delete extraction pod ${extractionPod}"; failed=1; }; podCreated=0; fi
  return "${failed}"
}
function OnSignal () { typeset status="${1:?}"; RecordError interrupted "received signal; exiting with status ${status}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

function WaitJsonPath () {
  typeset resource="${1:?}"; typeset name="${2:?}"; typeset expression="${3:?}"; typeset expected="${4:?}"; typeset timeoutSeconds="${5:?}"
  typeset deadline=$((SECONDS + timeoutSeconds)); typeset actual=''
  while ((SECONDS < deadline)); do actual="$(Oc get "${resource}" "${name}" -n "${ns}" -o "jsonpath=${expression}" 2>/dev/null || true)"; [[ "${actual}" == "${expected}" ]] && return 0; sleep 3; done
  return 1
}
function MountNTFS () {
  Oc exec -n "${ns}" "${extractionPod}" -- /bin/bash -ceu 'mkdir -p /mnt/windows && ntfs-3g -o ro /dev/disk-pvc /mnt/windows' >>"${extractionLog}" 2>&1
}
function ReadNTFSFile () {
  typeset ntfsPath="${1:?}"; typeset localPath="${2:?}"; typeset artifactType="${3:?}"; typeset required="${4:-1}"
  typeset temporary="${localPath}.tmp"; mkdir -p "$(dirname "${localPath}")"; rm -f "${temporary}"
  # Convert Windows path to NTFS path: C:\Windows\System32\file.txt -> /mnt/windows/Windows/System32/file.txt
  typeset unixPath="/mnt/windows/${ntfsPath#[Cc]:}"
  if ! Oc exec -n "${ns}" "${extractionPod}" -- cat "${unixPath}" > "${temporary}" 2>>"${extractionLog}"; then
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
function FindNTFSFiles () {
  typeset pattern="${1:?}"
  Oc exec -n "${ns}" "${extractionPod}" -- find /mnt/windows -iname "${pattern}" 2>>"${extractionLog}" | sed 's|^/mnt/windows||' || true
}

Log "creating extraction pod to mount disk directly (VM is stopped)"
jq -n --arg name "${extractionPod}" --arg ns "${ns}" --arg vm "${vm}" --arg pvc "${guestPvc}" \
  '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns,labels:{app:"bsod-extraction","target-vm":$vm}},spec:{restartPolicy:"Never",automountServiceAccountToken:false,containers:[{name:"extractor",image:"registry.access.redhat.com/ubi8:latest",command:["/bin/bash","-ceu","trap : TERM INT; sleep infinity & wait"],securityContext:{privileged:false,allowPrivilegeEscalation:true,readOnlyRootFilesystem:false,capabilities:{add:["SYS_ADMIN","DAC_OVERRIDE"]}},env:[{name:"LIBGUESTFS_CACHEDIR",value:"/dev/null"},{name:"TMPDIR",value:"/tmp"}],volumeDevices:[{name:"guest-disk",devicePath:"/dev/disk-pvc"}],volumeMounts:[{name:"scratch",mountPath:"/tmp"}]}],volumes:[{name:"guest-disk",persistentVolumeClaim:{claimName:$pvc,readOnly:true}},{name:"scratch",emptyDir:{medium:"Memory",sizeLimit:"2Gi"}}]}}' | Oc apply -f - >>"${extractionLog}"
podCreated=1; WaitJsonPath pod "${extractionPod}" '{.status.phase}' Running 180 || { RecordError extraction-pod 'extraction pod startup timed out'; exit 1; }
Oc exec -n "${ns}" "${extractionPod}" -- /bin/bash -ceu 'test -r /dev/disk-pvc && yum install -y ntfs-3g ntfsprogs >/dev/null 2>&1 && command -v ntfs-3g >/dev/null && command -v ntfsls >/dev/null' >>"${extractionLog}" 2>&1 || { RecordError extraction-pod 'ntfs-3g tools or block device is unavailable'; exit 1; }

typeset dumpOk=0; typeset evtxOk=0
Log "mounting Windows NTFS filesystem..."
MountNTFS || { RecordError extraction-pod 'failed to mount NTFS filesystem'; exit 1; }

# Locate ALL .DMP files anywhere on C: drive — Windows may write the dump to
# unexpected paths depending on CrashDumpEnabled type and DedicatedDumpFile config.
Log "searching for *.DMP files across entire C: drive..."
typeset allDumps=''; allDumps="$(Oc exec -n "${ns}" "${extractionPod}" -- find /mnt/windows -iname '*.dmp' -type f 2>>"${extractionLog}" | sed 's|^/mnt/windows||' | sort -u || true)"
if [[ -z "${allDumps}" ]]; then
  Log "no .DMP files found in recursive search"
else
  Log "found dumps:"
  while IFS= read -r dumpPath; do
    [[ -n "${dumpPath}" ]] && Log "  - ${dumpPath}"
  done <<<"${allDumps}"
fi
while IFS= read -r dumpPath; do
  [[ -n "${dumpPath}" ]] || continue
  typeset dumpBase; dumpBase="$(basename "${dumpPath}")"
  Log "extracting: ${dumpPath}"
  if ReadNTFSFile "${dumpPath}" "${outDir}/${dumpBase}" dump 0 0; then dumpOk=1; fi
done <<<"${allDumps}"
# Also check standard MEMORY.DMP path
if ((dumpOk == 0)); then
  if ReadNTFSFile 'C:\Windows\MEMORY.DMP' "${outDir}/MEMORY.DMP" dump 0 0; then dumpOk=1; fi
fi
# Check for minidumps
typeset minidumpList=''; minidumpList="$(Oc exec -n "${ns}" "${extractionPod}" -- find /mnt/windows/Windows/Minidump -iname '*.dmp' 2>>"${extractionLog}" | sed 's|^/mnt/windows||' || true)"
while IFS= read -r dumpPath; do
  [[ -n "${dumpPath}" ]] || continue
  typeset dumpBase; dumpBase="$(basename "${dumpPath}")"
  if ReadNTFSFile "${dumpPath}" "${outDir}/Minidump/${dumpBase}" dump 0 0; then dumpOk=1; fi
done <<<"${minidumpList}"
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
    Log "WARN: EVTX parser reported semantic failure — events.json may be incomplete"
  fi
else
  Log "WARN: EVTX parser failed or timed out — individual EVTX JSON parsing will proceed if available"
fi

# Parse individual EVTX files to separate JSON files using python-evtx for detailed event logs.
# Requires: pip install python-evtx
Log "parsing Application.evtx and System.evtx to JSON format..."
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import Evtx.Evtx' 2>/dev/null; then
    # Parse System.evtx
    if [[ -s "${outDir}/EventLogs/System.evtx" ]]; then
      typeset systemJson="${outDir}/EventLogs/System.json"
      RunTimed 120 python3 -c "
import json
from Evtx.Evtx import FileHeader
events = []
try:
  with open('${outDir}/EventLogs/System.evtx', 'rb') as f:
    fh = FileHeader(f)
    for record in fh.records():
      try:
        events.append(json.loads(record.xml()))
      except: pass
except Exception as e:
  print('Error parsing System.evtx:', e, file=__import__('sys').stderr)
print(json.dumps({'ok': True, 'source': 'System.evtx', 'eventCount': len(events), 'events': events}, indent=2))
" > "${systemJson}" 2>>"${extractionLog}" || Log "WARN: System.evtx JSON parse failed"
      [[ -s "${systemJson}" ]] && Log "System.evtx parsed: $(jq '.eventCount' "${systemJson}") events"
    fi
    # Parse Application.evtx
    if [[ -s "${outDir}/EventLogs/Application.evtx" ]]; then
      typeset appJson="${outDir}/EventLogs/Application.json"
      RunTimed 120 python3 -c "
import json
from Evtx.Evtx import FileHeader
events = []
try:
  with open('${outDir}/EventLogs/Application.evtx', 'rb') as f:
    fh = FileHeader(f)
    for record in fh.records():
      try:
        events.append(json.loads(record.xml()))
      except: pass
except Exception as e:
  print('Error parsing Application.evtx:', e, file=__import__('sys').stderr)
print(json.dumps({'ok': True, 'source': 'Application.evtx', 'eventCount': len(events), 'events': events}, indent=2))
" > "${appJson}" 2>>"${extractionLog}" || Log "WARN: Application.evtx JSON parse failed"
      [[ -s "${appJson}" ]] && Log "Application.evtx parsed: $(jq '.eventCount' "${appJson}") events"
    fi
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
  --mode rhov-snapshot-extraction --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename extraction-summary.json >/dev/null || summaryStatus=$?
((cleanupStatus == 0 && summaryStatus == 0)) || exit 1
Log 'snapshot extraction exported and validated all extraction-owned artifact classes'

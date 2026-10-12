# Crash Injector Scripts

Scripts that orchestrate intentional BSOD injection for testing the BSOD detector pipeline.

Designed for **deliberate, controlled crash testing** — not production use.

## Script Overview

### `trigger-bsod-intentional.sh`

**Purpose**: Main entry point for end-to-end intentional BSOD pipeline.

**Usage**:
```bash
BSOD_DET__VM__NAME="win2022-vm-hjoshi1" BSOD_DET__NAMESPACE="windows-bsod" \
  ./trigger-bsod-intentional.sh 0x01
```

**Arguments**:
- `crash_type` — NotMyFault bugcheck code (default: `0x01`)
  - `0x01` EXCEPTION_ACCESS_VIOLATION
  - `0x02` INVALID_KERNEL_HANDLE
  - `0x03` SYSTEM_SERVICE_EXCEPTION
  - `0x09` DRIVER_IRQL_NOT_LESS_OR_EQUAL
  - See `notmyfaultc64.exe /?` for full list

**Environment Variables**:

| Variable | Required | Purpose |
|---|---|---|
| `BSOD_DET__VM__NAME` | **Yes — no default** | Target Windows VM name |
| `BSOD_DET__NAMESPACE` | **Yes — no default** | Kubernetes namespace |
| `BSOD_DET__EVIDENCE__DIR` | No | Evidence root (default: `/mnt/persistent-bsod-evidence`) |
| `BSOD_DET__SNAPSHOT__CLASS` | No | Storage snapshot class |
| `BSOD_DET__MEMORY__DUMP_PVC` | No | Memory dump PVC name |
| `BSOD_RECOVERY_IMAGE` | No | Digest-pinned guestfs recovery image |
| `BSOD_DET__READY__TIMEOUT` | No | Watcher readiness timeout in seconds (default: 300) |
| `BSOD_DET__PREFLIGHT__TIMEOUT` | No | Preflight timeout in seconds (default: 300) |

**Execution Flow**:
```
1. Validate BSOD_DET__VM__NAME and BSOD_DET__NAMESPACE are set (no defaults)
2. Create run directory: /mnt/persistent-bsod-evidence/{TIMESTAMP}-intentional-{PID}-{RANDOM}/
3. Run preflight-rhov.sh
   ├─ QGA ping (5 retries)
   ├─ configure-dumps.ps1 on guest → validate rebootRequired=false
   └─ Write recovery-metadata.json
4. Start watch-crash.sh in background
5. Clean old dumps from guest (MEMORY.DMP, Minidump/*.dmp)
6. Inject BSOD via guest-agent.py exec-crash notmyfaultc64.exe /crash <type>
7. watch-crash.sh detects BSOD:
   ├─ Captures vm-memory.elf.tar.gz via virtctl memory-dump
   ├─ Captures screenshot, domain.xml, host-signals.json
   ├─ Stops VM (virtctl stop)
   ├─ Runs recover-natural-crash.sh (offline NTFS extraction)
   ├─ Restarts VM (virtctl start)
   └─ Writes evidence-summary.json
8. Return exit code (0=success, 1=failure)
```

**Output Structure**:
```
/mnt/persistent-bsod-evidence/{TIMESTAMP}-intentional-{PID}-{RANDOM}/
├── bsod-screenshot.png              VNC screenshot at crash moment
├── vm-memory.elf.tar.gz             PRIMARY: full physical memory (~800MB ELF)
├── domain.xml                       Libvirt domain config at crash
├── host-signals.json                Host diagnostics
├── launcher-compute.log             KVM virt-launcher logs
├── parse-dump-header.json           Bugcheck code (stub when elf2dmp disabled)
├── events.json                      Event crash detection (stub — run extract-evtx.py offline)
├── guestFS_sda3/                    NTFS extraction (partition name is dynamic)
│   └── Windows/System32/winevt/Logs/
│       ├── System.evtx              Windows System EventLog (~8MB)
│       └── Application.evtx        Windows Application EventLog (~6MB)
├── recovery-metadata.json           VM config, storage, armed epoch
├── checksums.sha256                 SHA-256 manifest of evidence files
├── stage-errors.jsonl               Per-stage error log
├── extraction.log                   guestfish extraction trace
├── extraction-summary.json          Recovery phase artifact inventory
├── evidence-summary.json            Final pipeline verdict (ok: true/false)
├── watcher.log                      Full watcher execution trace
└── watcher-ready                    Arming marker
```

**What is NOT captured (platform limitations)**:
- `MEMORY.DMP` — `AutoReboot=0` prevents the reboot that copies DedicatedDump.sys → MEMORY.DMP
- `Minidump/` — Requires pagefile.sys which Windows Server 2022 on KVM does not create
- `vm-memory-windows.dmp` — elf2dmp conversion disabled (17GB, developer runs offline)
- Volatility outputs — Developer tool, run offline against vm-memory.elf.tar.gz

**Exit Codes**:
- `0` — All required artifacts captured and validated
- `1` — Pipeline failed — check `stage-errors.jsonl` then `watcher.log`

**Diagnosing failures**:
```bash
run=/mnt/persistent-bsod-evidence/<run-id>
cat $run/stage-errors.jsonl | jq .
cat $run/evidence-summary.json | jq '{ok,stageErrors,missingRequiredArtifactTypes,invalidArtifacts}'
cat $run/extraction-summary.json | jq '{ok,stageErrors,missingRequiredArtifactTypes,invalidArtifacts}'
```

## Prerequisites

Before running the pipeline:

1. **VM Running**: `oc get vmi win2022-vm-hjoshi1 -n windows-bsod` shows `Running`
2. **QGA healthy**: `python3 guest-agent.py ping` returns `{}`
3. **Crash dump configured** (golden image settings — requires one prior reboot):
   - `CrashDumpEnabled=7` (Automatic)
   - `AutoReboot=0`
   - `DedicatedDumpFile=C:\DedicatedDump.sys` (15.9GB pre-allocated)
4. **Evidence mount**: `/mnt/persistent-bsod-evidence` writable and persistent
5. **NotMyFault binary**: `C:\Temp\nmf\notmyfaultc64.exe` on the VM
6. **Recovery image**: Digest-pinned `quay.io/konveyor/oadp-vmfr-access@sha256:...` pullable

**If preflight fails with rebootRequired=true**:
```bash
virtctl stop win2022-vm-hjoshi1 -n windows-bsod
virtctl start win2022-vm-hjoshi1 -n windows-bsod
# Wait for VM Ready, then re-run
```

## Troubleshooting

| Error | Where to look | Likely cause |
|---|---|---|
| QGA ping failed | `watcher.log` | VM frozen from previous BSOD — restart with virtctl |
| rebootRequired=true | preflight output | CrashDumpEnabled changed — do virtctl stop/start |
| source PVC attached | `extraction.log` | StopVM failed or VMI still running |
| oc cp unexpected EOF | `extraction.log` | Retry — transient network issue |
| missing: memory | `extraction-summary.json` | vm-memory.elf.tar.gz missing — virtctl dump failed |
| missing: evtx | `extraction-summary.json` | No System.evtx on any NTFS partition |

## Related Scripts

- `../host/preflight-rhov.sh` — VM validation and metadata generation
- `../host/watch-crash.sh` — BSOD detection and memory capture
- `../host/recover-natural-crash.sh` — Offline NTFS artifact extraction
- `../guest/configure-dumps.ps1` — Windows crash dump configuration
